import 'dart:math' as math;
import 'dart:typed_data';

/// Document-scan filters, CamScanner style. All run on raw RGBA in an isolate.
enum ScanFilter {
  original('Original'),
  magic('Magic Color'),
  enhance('Auto Enhance'),
  noShadow('No Shadow'),
  gray('Grayscale'),
  bw('B&W'),
  lighten('Lighten');

  const ScanFilter(this.label);
  final String label;
}

int _clamp(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

/// Box-blurred luminance (window ≈ 2r+1), computed on a downscaled copy to keep memory low
/// and sampled back at full size with bilinear interpolation.
Float32List _blurLum(Uint8List lum, int w, int h, int r) {
  final f = math.max(1, math.min(w, h) ~/ 500);
  final sw = (w + f - 1) ~/ f, sh = (h + f - 1) ~/ f;
  final small = Float64List(sw * sh);
  final counts = Int32List(sw * sh);
  for (var y = 0; y < h; y++) {
    final sy = y ~/ f;
    for (var x = 0; x < w; x++) {
      final k = sy * sw + x ~/ f;
      small[k] += lum[y * w + x];
      counts[k]++;
    }
  }
  for (var i = 0; i < small.length; i++) {
    small[i] /= math.max(1, counts[i]);
  }
  final sr = math.max(1, r ~/ f);
  final iw = sw + 1;
  final integ = Float64List(iw * (sh + 1));
  for (var y = 0; y < sh; y++) {
    var row = 0.0;
    for (var x = 0; x < sw; x++) {
      row += small[y * sw + x];
      integ[(y + 1) * iw + x + 1] = integ[y * iw + x + 1] + row;
    }
  }
  final blurred = Float64List(sw * sh);
  for (var y = 0; y < sh; y++) {
    final y0 = math.max(0, y - sr), y1 = math.min(sh, y + sr + 1);
    for (var x = 0; x < sw; x++) {
      final x0 = math.max(0, x - sr), x1 = math.min(sw, x + sr + 1);
      final s = integ[y1 * iw + x1] - integ[y0 * iw + x1] - integ[y1 * iw + x0] + integ[y0 * iw + x0];
      blurred[y * sw + x] = s / ((x1 - x0) * (y1 - y0));
    }
  }
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final fy = math.min(sh - 1.0, math.max(0.0, (y + 0.5) / f - 0.5));
    final y0 = fy.floor(), y1 = math.min(sh - 1, y0 + 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = math.min(sw - 1.0, math.max(0.0, (x + 0.5) / f - 0.5));
      final x0 = fx.floor(), x1 = math.min(sw - 1, x0 + 1);
      final tx = fx - x0;
      final a = blurred[y0 * sw + x0] * (1 - tx) + blurred[y0 * sw + x1] * tx;
      final b = blurred[y1 * sw + x0] * (1 - tx) + blurred[y1 * sw + x1] * tx;
      out[y * w + x] = a * (1 - ty) + b * ty;
    }
  }
  return out;
}

Uint8List _luminance(Uint8List p, int w, int h) {
  final lum = Uint8List(w * h);
  for (var i = 0, j = 0; j < lum.length; i += 4, j++) {
    lum[j] = (p[i] * 77 + p[i + 1] * 150 + p[i + 2] * 29) >> 8;
  }
  return lum;
}

/// Low/high percentiles of luminance.
(int, int) _percentiles(Uint8List lum, double lo, double hi) {
  final hist = List<int>.filled(256, 0);
  for (final v in lum) {
    hist[v]++;
  }
  final n = lum.length;
  var acc = 0, l = 0, hgh = 255;
  var foundLo = false;
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (!foundLo && acc >= n * lo) {
      l = i;
      foundLo = true;
    }
    if (acc >= n * hi) {
      hgh = i;
      break;
    }
  }
  if (hgh - l < 20) return (0, 255);
  return (l, hgh);
}

void _saturate(Uint8List p, double amount) {
  for (var i = 0; i < p.length; i += 4) {
    final l = (p[i] * 77 + p[i + 1] * 150 + p[i + 2] * 29) >> 8;
    p[i] = _clamp(l + (p[i] - l) * amount);
    p[i + 1] = _clamp(l + (p[i + 1] - l) * amount);
    p[i + 2] = _clamp(l + (p[i + 2] - l) * amount);
  }
}

void _stretch(Uint8List p, int lo, int hi, {double gamma = 1}) {
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    var t = (v - lo) / math.max(1, hi - lo);
    t = t.clamp(0.0, 1.0);
    if (gamma != 1) t = math.pow(t, gamma).toDouble();
    lut[v] = _clamp(t * 255);
  }
  for (var i = 0; i < p.length; i += 4) {
    p[i] = lut[p[i]];
    p[i + 1] = lut[p[i + 1]];
    p[i + 2] = lut[p[i + 2]];
  }
}

/// Divides out uneven lighting/shadows using a large-window background estimate.
void _flattenLighting(Uint8List p, int w, int h) {
  final lum = _luminance(p, w, h);
  final r = math.max(8, math.max(w, h) ~/ 24);
  // Background ≈ bright paper: blur a max-ish version (dilate by blur of lifted values).
  final bg = _blurLum(lum, w, h, r);
  for (var i = 0, j = 0; j < lum.length; i += 4, j++) {
    final b = math.max(bg[j], 1.0);
    // Paper tends to be brighter than the local mean (text is sparse) -> scale by ~1.12.
    final k = 255 / math.min(255.0, b * 1.12);
    p[i] = _clamp(p[i] * k);
    p[i + 1] = _clamp(p[i + 1] * k);
    p[i + 2] = _clamp(p[i + 2] * k);
  }
}

/// Entry point for `compute`: (rgba, width, height, filter index). Returns a new buffer.
Uint8List applyScanFilter((Uint8List, int, int, int) args) {
  final (src, w, h, fi) = args;
  final filter = ScanFilter.values[fi];
  final p = Uint8List.fromList(src);
  switch (filter) {
    case ScanFilter.original:
      break;
    case ScanFilter.enhance:
      final (lo, hi) = _percentiles(_luminance(p, w, h), 0.01, 0.99);
      _stretch(p, lo, hi);
      _saturate(p, 1.15);
    case ScanFilter.magic:
      _flattenLighting(p, w, h);
      final (lo, hi) = _percentiles(_luminance(p, w, h), 0.02, 0.90);
      _stretch(p, lo, math.max(lo + 30, hi), gamma: 1.15);
      _saturate(p, 1.35);
    case ScanFilter.noShadow:
      _flattenLighting(p, w, h);
      final (lo, _) = _percentiles(_luminance(p, w, h), 0.01, 0.99);
      _stretch(p, lo, 250);
    case ScanFilter.gray:
      final lum = _luminance(p, w, h);
      final (lo, hi) = _percentiles(lum, 0.01, 0.98);
      for (var i = 0, j = 0; j < lum.length; i += 4, j++) {
        final v = _clamp((lum[j] - lo) * 255 / math.max(1, hi - lo));
        p[i] = v;
        p[i + 1] = v;
        p[i + 2] = v;
      }
    case ScanFilter.bw:
      // Adaptive (local-mean) threshold: crisp text even with shadows.
      final lum = _luminance(p, w, h);
      final r = math.max(7, math.max(w, h) ~/ 60);
      final mean = _blurLum(lum, w, h, r);
      for (var i = 0, j = 0; j < lum.length; i += 4, j++) {
        final v = lum[j] < mean[j] * 0.88 ? 0 : 255;
        p[i] = v;
        p[i + 1] = v;
        p[i + 2] = v;
      }
    case ScanFilter.lighten:
      final (lo, hi) = _percentiles(_luminance(p, w, h), 0.005, 0.97);
      _stretch(p, lo, hi, gamma: 0.75);
  }
  for (var i = 3; i < p.length; i += 4) {
    p[i] = 255;
  }
  return p;
}
