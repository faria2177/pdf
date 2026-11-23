import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:pdfrx/pdfrx.dart';

/// A4 in PDF points.
const a4Width = 595.0;
const a4Height = 842.0;

class JpegData {
  const JpegData(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;
}

/// Decodes any image Flutter understands (PNG, JPEG, WebP, GIF, BMP) and re-encodes it as JPEG,
/// downscaling so the longer side is at most [maxSide] pixels.
Future<JpegData> imageToJpeg(Uint8List bytes, {int maxSide = 2200, int quality = 88}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      if (w <= maxSide && h <= maxSide) return ui.TargetImageSize(width: w, height: h);
      if (w >= h) return ui.TargetImageSize(width: maxSide, height: (maxSide * h / w).round());
      return ui.TargetImageSize(width: (maxSide * w / h).round(), height: maxSide);
    },
  );
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    final w = image.width, h = image.height;
    image.dispose();
    final jpeg = await compute(_encode, (rgba, w, h, quality));
    return JpegData(jpeg, w, h);
  } finally {
    codec.dispose();
  }
}

Uint8List _encode((Uint8List, int, int, int) args) {
  final (rgba, w, h, q) = args;
  return JpegEncoder().compress(rgba, w, h, q);
}

/// Creates a one-page PDF holding [bytes] (an image). The page is A4 portrait/landscape
/// matching the image orientation when [fitA4] is true, otherwise sized to the image.
Future<PdfDocument> imageToPdfDocument(Uint8List bytes, String name, {bool fitA4 = true}) async {
  final jpeg = await imageToJpeg(bytes);
  double width, height;
  if (fitA4) {
    final landscape = jpeg.width > jpeg.height;
    final boxW = landscape ? a4Height : a4Width;
    final boxH = landscape ? a4Width : a4Height;
    final scale = (boxW / jpeg.width) < (boxH / jpeg.height) ? boxW / jpeg.width : boxH / jpeg.height;
    width = jpeg.width * scale;
    height = jpeg.height * scale;
  } else {
    // 150 dpi -> points
    width = jpeg.width * 72 / 150;
    height = jpeg.height * 72 / 150;
  }
  return PdfDocument.createFromJpegData(jpeg.data, width: width, height: height, sourceName: name);
}

/// A white page of the given size (used for "Insert blank page").
Future<PdfDocument> blankPageDocument({double width = a4Width, double height = a4Height}) async {
  const px = 64;
  final ph = (px * height / width).round().clamp(1, 4096);
  final rgba = Uint8List(px * ph * 4)..fillRange(0, px * ph * 4, 255);
  final jpeg = await compute(_encode, (rgba, px, ph, 90));
  return PdfDocument.createFromJpegData(jpeg, width: width, height: height, sourceName: 'blank-${DateTime.now().microsecondsSinceEpoch}');
}

/// Renders a page to PNG at [dpi].
Future<Uint8List?> renderPageToPng(PdfPage page, {double dpi = 150}) async {
  final scale = dpi / 72;
  final w = (page.width * scale).round();
  final h = (page.height * scale).round();
  final rendered = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xFFFFFFFF);
  if (rendered == null) return null;
  try {
    final image = await rendered.createImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    rendered.dispose();
  }
}
