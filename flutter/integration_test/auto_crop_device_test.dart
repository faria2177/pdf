// Runs the real auto-crop (Dart detectors + native doclens warp) on an
// Android emulator against synthetic photos that copy the reported failure:
// an ID card in a clear sleeve on a grey table, shot in portrait (EXIF 6),
// at 12 MP and 50 MP. Checks both the detected corners and the actual
// cropped JPEG (its border must be the card, not the table).
//
//   python3 tool/make_scan_fixtures.py
//   flutter test integration_test/auto_crop_device_test.dart -d <device>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_studio/ds/services/card_guide_detector.dart';
import 'package:pdf_studio/ds/services/document_edges.dart';

import 'scan_fixture_data.dart';

/// Overlap of two convex quads (normalized), rasterised on a 240×240 grid.
double quadIou(List<Offset> a, List<Offset> b) {
  bool inside(List<Offset> q, Offset p) {
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final s = q[i];
      final e = q[(i + 1) % 4];
      final c = (e.dx - s.dx) * (p.dy - s.dy) - (e.dy - s.dy) * (p.dx - s.dx);
      final d = c > 0 ? 1 : c < 0 ? -1 : 0;
      if (d != 0) {
        if (sign == 0) {
          sign = d;
        } else if (d != sign) {
          return false;
        }
      }
    }
    return true;
  }

  const n = 240;
  var both = 0;
  var either = 0;
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final p = Offset((x + .5) / n, (y + .5) / n);
      final ia = inside(a, p);
      final ib = inside(b, p);
      if (ia && ib) both++;
      if (ia || ib) either++;
    }
  }
  return either == 0 ? 0 : both / either;
}

/// Share of a thin ring (1–1.8 % inside the edge) that is bright paper or
/// card. A crop that includes the grey table scores low.
double brightRing(img.Image page) {
  var bright = 0;
  var total = 0;
  void sample(int x, int y) {
    final p = page.getPixel(x, y);
    final lum = .299 * p.r + .587 * p.g + .114 * p.b;
    total++;
    if (lum > 195) bright++;
  }

  final w = page.width;
  final h = page.height;
  for (final f in [.01, .018]) {
    final dx = (w * f).round();
    final dy = (h * f).round();
    for (var x = dx; x < w - dx; x += 3) {
      sample(x, dy);
      sample(x, h - 1 - dy);
    }
    for (var y = dy; y < h - dy; y += 3) {
      sample(dx, y);
      sample(w - 1 - dx, y);
    }
  }
  return total == 0 ? 0 : bright / total;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('auto crop cuts exactly the card / page', (tester) async {
    final dir = await getTemporaryDirectory();
    final shots =
        Directory('${(await getExternalStorageDirectory())!.path}/autocrop');
    await shots.create(recursive: true);
    final failures = <String>[];
    for (final entry in scanScenes.entries) {
      final (data, flat, aspect, card) = entry.value;
      final file = File('${dir.path}/${entry.key}.jpg');
      await file.writeAsBytes(base64Decode(data), flush: true);
      final truth = [
        for (var i = 0; i < 8; i += 2) Offset(flat[i], flat[i + 1]),
      ];
      final watch = Stopwatch()..start();
      // guide_* scenes copy the ID camera: only the guide frame counts.
      final guided = entry.key.startsWith('guide_');
      final detection = guided
          ? await CardGuideDetector.detect(file.path)
          : await DocumentEdges.detectSafeStillOutline(file.path,
              preferIdCardBounds: card);
      final quad = detection?.quad;
      final iou = quad == null ? 0.0 : quadIou(quad.points, truth);
      final AutoCropBatch batch;
      if (guided) {
        final path = await CardGuideDetector.crop(file.path);
        batch = AutoCropBatch([path ?? file.path], path == null ? 0 : 1);
      } else {
        batch = await DocumentEdges.autoCropFiles([file.path],
            preferIdCardBounds: card);
      }
      final out = File(batch.paths.single);
      await out.copy('${shots.path}/${entry.key}_crop.jpg');
      final page = img.decodeImage(await out.readAsBytes());
      var ring = 0.0;
      var ratio = 0.0;
      if (page != null) {
        ring = brightRing(page);
        ratio = math.max(page.width, page.height) /
            math.min(page.width, page.height);
        final small = base64Encode(img.encodeJpg(
            img.copyResize(page, width: 240), quality: 60));
        for (var i = 0; i < small.length; i += 700) {
          // ignore: avoid_print
          print('SHOT ${entry.key} ${i ~/ 700} '
              '${small.substring(i, math.min(i + 700, small.length))}');
        }
      }
      // ignore: avoid_print
      print('AUTOCROP ${entry.key} iou=${iou.toStringAsFixed(3)} '
          'ring=${ring.toStringAsFixed(2)} ratio=${ratio.toStringAsFixed(2)}'
          '/${aspect.toStringAsFixed(2)} size=${page?.width}x${page?.height} '
          'space=${detection?.imageSize} ms=${watch.elapsedMilliseconds} '
          'cropped=${batch.croppedCount} quad=${quad?.points.map((p) => '${p.dx.toStringAsFixed(3)},${p.dy.toStringAsFixed(3)}').join(' ')}');
      if (iou < .88 ||
          batch.croppedCount != 1 ||
          ring < .85 ||
          (ratio - aspect).abs() / aspect > .10) {
        failures.add('${entry.key}: iou ${iou.toStringAsFixed(3)} '
            'ring ${ring.toStringAsFixed(2)} ratio ${ratio.toStringAsFixed(2)} '
            'cropped ${batch.croppedCount}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
