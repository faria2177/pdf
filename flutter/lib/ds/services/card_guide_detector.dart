import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:doclens/doclens.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'document_edges.dart';

/// ID-card camera: find the card *inside the on-screen guide box*.
///
/// The camera shows a card-shaped frame (88 % of the preview width, ID-1
/// ratio, centred). A full-frame detector happily locks on to a sheet of
/// paper, a book or the table edge next to the card. Here the search is
/// limited to a band around that frame, the card is detected there (with
/// the sleeve/holder refinement), and the result must actually sit in the
/// frame — like CamScanner's ID mode.
class CardGuideDetector {
  const CardGuideDetector._();

  /// Guide width as a share of the photo width. The preview fills the
  /// screen (BoxFit.cover), so on tall screens the frame covers a little
  /// less of the photo; the search band below allows for that.
  static const double guideWidth = .88;
  static const double cardRatio = 1.58;

  /// Detects the card in the guide area of a camera still. Returns null when
  /// nothing card-like is inside the frame.
  static Future<ImageDetection?> detect(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final roi = await compute(_cropWorker, bytes);
      if (roi == null) return null;
      final (Uint8List jpeg, int x0, int y0, int rw, int rh, int w, int h) = roi;
      final file = File(p.join(Directory.systemTemp.path,
          'ds_card_roi_${DateTime.now().microsecondsSinceEpoch}.jpg'));
      await file.writeAsBytes(jpeg, flush: true);
      try {
        final found = await DocumentEdges.detectSafeStillOutline(file.path,
            preferIdCardBounds: true);
        final quad = found?.quad;
        if (quad == null) return null;
        final mapped = [
          for (final pt in quad.points)
            Offset((x0 + pt.dx * rw) / w, (y0 + pt.dy * rh) / h),
        ];
        if (!_insideGuide(mapped, w, h)) {
          debugPrint('[AutoCrop] card found outside the guide frame; ignored');
          return null;
        }
        return ImageDetection(
          quad: Quad(
            topLeft: mapped[0],
            topRight: mapped[1],
            bottomRight: mapped[2],
            bottomLeft: mapped[3],
          ),
          imageSize: Size(w.toDouble(), h.toDouble()),
        );
      } finally {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('[AutoCrop] guide detection skipped: $error');
      return null;
    }
  }

  /// Detects and cuts the card from a camera still; null if not found.
  static Future<String?> crop(String imagePath) async {
    final detection = await detect(imagePath);
    if (detection == null) return null;
    return DoclensPlatform.instance.warpImage(
      rawImagePath: imagePath,
      quad: detection.quadIn,
      jpegQuality: 95,
      enhancement: ImageEnhancement.none,
      autoOrientation: AutoOrientation.auto,
      trimShadow: true,
      quadSpace: detection.imageSize,
    );
  }

  /// Guide frame in upright photo pixels.
  static Rect guideRect(int w, int h) {
    final gw = w * guideWidth;
    final gh = gw / cardRatio;
    return Rect.fromCenter(center: Offset(w / 2, h / 2), width: gw, height: gh);
  }

  static bool _insideGuide(List<Offset> quad, int w, int h) {
    final g = guideRect(w, h);
    final pts = [for (final q in quad) Offset(q.dx * w, q.dy * h)];
    final centre = pts.reduce((a, b) => a + b) / 4;
    // Centre within the frame (with some slack for an off-centre hold).
    if (!g.inflate(g.height * .25).contains(centre)) return false;
    // Large enough: at least 30 % of the frame, at most a bit beyond it.
    var area = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i], b = pts[(i + 1) % 4];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    area = area.abs() / 2;
    final frame = g.width * g.height;
    return area >= frame * .30 && area <= frame * 2.2;
  }

  /// Upright decode, then the band around the guide frame as JPEG.
  static (Uint8List, int, int, int, int, int, int)? _cropWorker(
      Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final source = img.bakeOrientation(decoded);
    final w = source.width, h = source.height;
    // The ID camera UI is portrait-only; a landscape still means the phone
    // was turned, and the frame no longer maps to the photo.
    if (w > h) return null;
    final g = guideRect(w, h);
    final band = g.height * 1.7;
    final y0 = math.max(0, (g.center.dy - band / 2).round());
    final y1 = math.min(h, (g.center.dy + band / 2).round());
    final roi = img.copyCrop(source, x: 0, y: y0, width: w, height: y1 - y0);
    // Detectors work on ~1000 px anyway; keep the file light.
    final scale = math.min(1.0, 2000 / w);
    final small = scale < 1
        ? img.copyResize(roi,
            width: (w * scale).round(),
            interpolation: img.Interpolation.average)
        : roi;
    return (img.encodeJpg(small, quality: 92), 0, y0, w, y1 - y0, w, h);
  }
}
