import 'dart:io';
import 'dart:ui';

import 'package:doclens/doclens.dart';
import 'package:flutter/foundation.dart';

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
    // A band across the middle of the photo, generous enough for any
    // screen/photo shape (the exact frame check follows below). Made
    // natively as a small upright JPEG, so nothing decodes the full photo.
    const band = Rect.fromLTRB(0, .125, 1, .875);
    final roi = await DocumentEdges.uprightRegion(imagePath, region: band, maxSide: 1600);
    if (roi == null) return null;
    try {
      final w = roi.fullSize.width.round(), h = roi.fullSize.height.round();
      // The ID camera UI is portrait-only; a landscape still means the
      // phone was turned and the frame no longer maps to the photo.
      if (w > h) return null;
      final found = await DocumentEdges.detectSafeStillOutline(roi.path,
          preferIdCardBounds: true);
      final quad = found?.quad;
      if (quad == null) return null;
      final mapped = [
        for (final pt in quad.points)
          Offset(pt.dx, band.top + pt.dy * band.height),
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
    } catch (error) {
      debugPrint('[AutoCrop] guide detection skipped: $error');
      return null;
    } finally {
      try {
        await File(roi.path).delete();
      } catch (_) {}
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
}
