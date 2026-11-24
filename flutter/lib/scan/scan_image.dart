import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:material_ui/material_ui.dart';

import 'image_filters.dart';

/// One scanned page and the edits applied to it (non-destructive).
class ScanImage {
  ScanImage(this.path, {this.turns = 0, this.crop = const Rect.fromLTWH(0, 0, 1, 1), this.filter = ScanFilter.magic});

  String path; // original JPEG from the scanner
  int turns; // quarter turns clockwise
  Rect crop; // 0..1 in the rotated image
  ScanFilter filter;
  int version = 0; // bumps on every edit (cache key)

  ScanImage copy() => ScanImage(path, turns: turns, crop: crop, filter: filter);
}

/// Decodes [path] so its longest side is at most [maxSide].
Future<ui.Image> decodeImageFile(String path, {int maxSide = 2400}) async {
  final bytes = await File(path).readAsBytes();
  return decodeImageBytes(bytes, maxSide: maxSide);
}

Future<ui.Image> decodeImageBytes(Uint8List bytes, {int maxSide = 2400}) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
    buf,
    getTargetSize: (w, h) {
      final s = math.min(1.0, maxSide / math.max(w, h));
      return ui.TargetImageSize(width: math.max(1, (w * s).round()), height: math.max(1, (h * s).round()));
    },
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Draws [img] rotated by [turns] and cropped to [crop] (0..1 of the rotated image).
Future<ui.Image> transformImage(ui.Image img, int turns, Rect crop) async {
  final t = turns % 4;
  final iw = img.width.toDouble(), ih = img.height.toDouble();
  final rw = t.isOdd ? ih : iw, rh = t.isOdd ? iw : ih;
  final c = Rect.fromLTRB(crop.left * rw, crop.top * rh, crop.right * rw, crop.bottom * rh);
  final ow = math.max(1, c.width.round()), oh = math.max(1, c.height.round());
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.translate(-c.left, -c.top);
  switch (t) {
    case 1:
      canvas.translate(rw, 0);
      canvas.rotate(math.pi / 2);
    case 2:
      canvas.translate(rw, rh);
      canvas.rotate(math.pi);
    case 3:
      canvas.translate(0, rh);
      canvas.rotate(3 * math.pi / 2);
  }
  canvas.drawImage(img, Offset.zero, Paint()..filterQuality = FilterQuality.high);
  return rec.endRecording().toImage(ow, oh);
}

Future<Uint8List> imageToRgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

Future<ui.Image> rgbaToImage(Uint8List rgba, int w, int h) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(rgba);
  final desc = ui.ImageDescriptor.raw(buf, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await desc.instantiateCodec();
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
    desc.dispose();
    buf.dispose();
  }
}

/// Fully processed page (rotate, crop, filter) as RGBA.
Future<(Uint8List, int, int)> renderScan(ScanImage s, {int maxSide = 2400, ScanFilter? filter}) async {
  final src = await decodeImageFile(s.path, maxSide: maxSide);
  final t = await transformImage(src, s.turns, s.crop);
  src.dispose();
  final rgba = await imageToRgba(t);
  final w = t.width, h = t.height;
  t.dispose();
  final f = filter ?? s.filter;
  if (f == ScanFilter.original) return (rgba, w, h);
  return (await compute(applyScanFilter, (rgba, w, h, f.index)), w, h);
}

Future<ui.Image> renderScanImage(ScanImage s, {int maxSide = 1400, ScanFilter? filter}) async {
  final (rgba, w, h) = await renderScan(s, maxSide: maxSide, filter: filter);
  return rgbaToImage(rgba, w, h);
}

Uint8List _jpeg((Uint8List, int, int, int) a) {
  final (rgba, w, h, q) = a;
  return JpegEncoder().compress(rgba, w, h, q);
}

Future<Uint8List> rgbaToJpeg(Uint8List rgba, int w, int h, int quality) => compute(_jpeg, (rgba, w, h, quality));

Future<Uint8List> imageToJpeg(ui.Image img, int quality) async {
  final rgba = await imageToRgba(img);
  return rgbaToJpeg(rgba, img.width, img.height, quality);
}
