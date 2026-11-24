import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:doclens/doclens.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Finds the real card inside a clear sleeve / holder / laminate pouch.
///
/// The detectors often return the outline of the plastic sleeve (or of a
/// strip of table) around an ID card. This stage rectifies the detected quad,
/// walks inward from each side and looks for the first straight edge that
/// runs the whole length of that side and separates a uniform margin (sleeve,
/// table) from *card material* — pixels that look like the card's own
/// interior. Printed frame lines, photos and colour bands fail that test, so a
/// correctly detected card keeps its outline.
class CardSleeveRefiner {
  const CardSleeveRefiner._();

  static Future<ImageDetection> refine(
      String imagePath, ImageDetection detection) async {
    final quad = detection.quad;
    if (quad == null) return detection;
    try {
      final bytes = await File(imagePath).readAsBytes();
      final flat = <double>[
        for (final p in quad.points) ...[p.dx, p.dy],
      ];
      final inner = await compute(_worker, <String, Object>{
        'bytes': bytes,
        'quad': flat,
      });
      if (inner == null) return detection;
      debugPrint('[AutoCrop] card found inside sleeve/holder: '
          '${inner.map((v) => v.toStringAsFixed(3)).join(',')}');
      return ImageDetection(
        quad: Quad(
          topLeft: Offset(inner[0], inner[1]),
          topRight: Offset(inner[2], inner[3]),
          bottomRight: Offset(inner[4], inner[5]),
          bottomLeft: Offset(inner[6], inner[7]),
        ),
        imageSize: detection.imageSize,
      );
    } catch (error) {
      debugPrint('[AutoCrop] sleeve refinement skipped: $error');
      return detection;
    }
  }

  static List<double>? _worker(Map<String, Object> args) =>
      refineBytes(args['bytes']! as Uint8List, args['quad']! as List<double>);

  /// Pure; [normalized] is TL, TR, BR, BL as x,y in 0..1. Returns the inner
  /// card corners (same format) or null when there is no clear inner card.
  static List<double>? refineBytes(Uint8List bytes, List<double> normalized) {
    if (normalized.length != 8 ||
        normalized.any((v) => !v.isFinite || v < 0 || v > 1)) {
      return null;
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final source = img.bakeOrientation(decoded);
    final scale = math.min(1.0, 1400.0 / math.max(source.width, source.height));
    final w = math.max(1, (source.width * scale).round());
    final h = math.max(1, (source.height * scale).round());
    final work = scale < 1
        ? img.copyResize(source,
            width: w, height: h, interpolation: img.Interpolation.average)
        : source;
    final gray = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = work.getPixel(x, y);
        gray[y * w + x] = (.299 * p.r + .587 * p.g + .114 * p.b).toDouble();
      }
    }
    final pts = [
      for (var i = 0; i < 8; i += 2)
        Offset(normalized[i] * w, normalized[i + 1] * h),
    ];
    final out = refineGray(gray, w, h, pts);
    if (out == null) return null;
    return [for (final p in out) ...[p.dx / w, p.dy / h]];
  }

  /// [quad] in pixels of the [w]x[h] grey image. Returns inner corners in
  /// the same pixels, or null.
  static List<Offset>? refineGray(
      Float32List gray, int w, int h, List<Offset> quad) {
    final hom = _Homography.unitSquareTo(quad);
    if (hom == null) return null;
    final qw = ((quad[1] - quad[0]).distance + (quad[2] - quad[3]).distance) / 2;
    final qh = ((quad[3] - quad[0]).distance + (quad[2] - quad[1]).distance) / 2;
    if (qw < 40 || qh < 40) return null;
    var rw = 480, rh = math.max(60, (480 * qh / qw).round());
    if (rh > 480) {
      rh = 480;
      rw = math.max(60, (480 * qw / qh).round());
    }
    // Rectified grey image of the detected quad.
    final r = Float32List(rw * rh);
    for (var j = 0; j < rh; j++) {
      final v = (j + .5) / rh;
      for (var i = 0; i < rw; i++) {
        final p = hom.map((i + .5) / rw, v);
        r[j * rw + i] = _bilinear(gray, w, h, p.dx, p.dy);
      }
    }
    // Typical brightness of the card's own interior.
    final centre = <double>[];
    for (var j = (rh * .25).round(); j < (rh * .75).round(); j += 2) {
      for (var i = (rw * .25).round(); i < (rw * .75).round(); i += 2) {
        centre.add(r[j * rw + i]);
      }
    }
    centre.sort();
    final paper = centre[centre.length ~/ 2];

    final insets = <double>[];
    final strips = <double>[];
    final signs = <int>[];
    for (var side = 0; side < 4; side++) {
      // side: 0 left, 1 right, 2 top, 3 bottom. a = along, d = inward.
      final along = side < 2 ? rh : rw;
      final depth = side < 2 ? rw : rh;
      double at(int a, int d) => switch (side) {
            0 => r[a * rw + d],
            1 => r[a * rw + (rw - 1 - d)],
            2 => r[d * rw + a],
            _ => r[(rh - 1 - d) * rw + a],
          };
      double band(int a0, int a1, int d0, int d1) {
        var s = 0.0;
        var n = 0;
        for (var a = a0; a < a1; a++) {
          for (var d = math.max(0, d0); d < math.min(depth, d1); d++) {
            s += at(a, d);
            n++;
          }
        }
        return n == 0 ? 0 : s / n;
      }

      final lo = math.max(3, (depth * .015).round());
      final hi = (depth * .14).round();
      const seg = 8;
      final a0 = (along * .1).round();
      final a1 = (along * .9).round();
      final bounds = [for (var k = 0; k <= seg; k++) a0 + ((a1 - a0) * k / seg).round()];
      final profile = <(int, double, int)>[]; // d, strength, sign
      int? first;
      for (var d = lo; d <= hi; d++) {
        final steps = [
          for (var k = 0; k < seg; k++)
            band(bounds[k], bounds[k + 1], d + 1, d + 4) -
                band(bounds[k], bounds[k + 1], d - 3, d),
        ];
        final sorted = [...steps]..sort();
        final med = (sorted[seg ~/ 2 - 1] + sorted[seg ~/ 2]) / 2;
        final sign = med >= 0 ? 1 : -1;
        final abs = [for (final s in steps) s.abs()]..sort();
        final strength = (abs[seg ~/ 2 - 1] + abs[seg ~/ 2]) / 2;
        final agree = steps.where((s) => s.abs() > 12 && (s >= 0 ? 1 : -1) == sign).length / seg;
        profile.add((d, strength, sign));
        if (first == null && agree >= .75 && strength >= 25) first = profile.length - 1;
        if (first != null && profile.length - 1 >= first + 4) break;
      }
      if (first == null) return null;
      var best = profile[first];
      for (var k = first; k < profile.length; k++) {
        final c = profile[k];
        if (c.$3 == best.$3 && c.$2 > best.$2) best = c;
      }
      final d = best.$1;
      final stripMean = band(a0, a1, 1, math.max(2, d - 2));
      // Uniformity of the margin.
      var ss = 0.0;
      var n = 0;
      for (var a = a0; a < a1; a++) {
        for (var dd = 1; dd < math.max(2, d - 2); dd++) {
          final v = at(a, dd) - stripMean;
          ss += v * v;
          n++;
        }
      }
      final stripStd = n == 0 ? 0.0 : math.sqrt(ss / n);
      final innerMean = band(a0, a1, d + 2, d + 2 + math.max(4, (depth * .02).round()));
      if ((innerMean - stripMean).abs() < 18) return null;
      // Inside the edge must look like the card itself; outside must not.
      if ((innerMean - paper).abs() >= (stripMean - paper).abs() * .5) return null;
      if (stripStd > 16) return null;
      insets.add(d / depth);
      strips.add(stripMean);
      signs.add(innerMean > stripMean ? 1 : -1);
    }
    if (strips.reduce(math.max) - strips.reduce(math.min) > 28) return null;
    if (signs.toSet().length != 1) return null;
    final (l, rt, t, b) = (insets[0], insets[1], insets[2], insets[3]);
    final iw = (1 - l - rt) * qw;
    final ih = (1 - t - b) * qh;
    if (iw <= 0 || ih <= 0) return null;
    final ratio = math.max(iw, ih) / math.min(iw, ih);
    if (ratio < 1.3 || ratio > 1.9) return null;
    return [
      hom.map(l, t),
      hom.map(1 - rt, t),
      hom.map(1 - rt, 1 - b),
      hom.map(l, 1 - b),
    ];
  }

  static double _bilinear(Float32List g, int w, int h, double x, double y) {
    x = x.clamp(0.0, w - 1.001).toDouble();
    y = y.clamp(0.0, h - 1.001).toDouble();
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final i = y0 * w + x0;
    final top = g[i] * (1 - fx) + g[i + 1] * fx;
    final bot = g[i + w] * (1 - fx) + g[i + w + 1] * fx;
    return top * (1 - fy) + bot * fy;
  }
}

/// Projective map of the unit square onto a quad (TL, TR, BR, BL).
class _Homography {
  const _Homography(this.a, this.b, this.c, this.d, this.e, this.f, this.g, this.h);
  final double a, b, c, d, e, f, g, h;

  static _Homography? unitSquareTo(List<Offset> q) {
    final x0 = q[0].dx, y0 = q[0].dy, x1 = q[1].dx, y1 = q[1].dy;
    final x2 = q[2].dx, y2 = q[2].dy, x3 = q[3].dx, y3 = q[3].dy;
    final dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
    final sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
    final den = dx1 * dy2 - dx2 * dy1;
    if (den.abs() < 1e-9) return null;
    final g = (sx * dy2 - dx2 * sy) / den;
    final h = (dx1 * sy - sx * dy1) / den;
    return _Homography(x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
        y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h);
  }

  Offset map(double u, double v) {
    final w = g * u + h * v + 1;
    return Offset((a * u + b * v + c) / w, (d * u + e * v + f) / w);
  }
}
