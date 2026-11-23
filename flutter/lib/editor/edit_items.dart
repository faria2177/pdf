import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Everything the editor draws on a page. Coordinates are 0..1 of the displayed page
/// (x by width, y by height); sizes that must stay proportional use page height.
/// Items are immutable so undo/redo can keep cheap snapshots.
sealed class EditItem {
  const EditItem(this.id);
  final int id;
  Rect get bounds;
  EditItem moved(Offset delta);
  EditItem resized(Rect rect);
}

class TextItem extends EditItem {
  const TextItem({
    required int id,
    required this.text,
    required this.rect,
    required this.fontSize,
    required this.color,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.background,
    this.align = TextAlign.left,
    this.fontFamily,
  }) : super(id);

  final String text;
  final Rect rect; // width wraps; height grows with content
  final double fontSize; // fraction of page height
  final Color color;
  final bool bold;
  final bool italic;
  final bool underline;
  final Color? background;
  final TextAlign align;
  final String? fontFamily;

  @override
  Rect get bounds => rect;

  TextItem copyWith({
    String? text,
    Rect? rect,
    double? fontSize,
    Color? color,
    bool? bold,
    bool? italic,
    bool? underline,
    Color? background,
    bool clearBackground = false,
    TextAlign? align,
    String? fontFamily,
  }) =>
      TextItem(
        id: id,
        text: text ?? this.text,
        rect: rect ?? this.rect,
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        background: clearBackground ? null : (background ?? this.background),
        align: align ?? this.align,
        fontFamily: fontFamily ?? this.fontFamily,
      );

  @override
  TextItem moved(Offset d) => copyWith(rect: rect.shift(d));

  @override
  TextItem resized(Rect r) {
    final scale = rect.height <= 0 ? 1.0 : (r.height / rect.height);
    return copyWith(rect: r, fontSize: (fontSize * scale).clamp(0.005, 0.3));
  }

  TextStyle style(Size page) => TextStyle(
        fontSize: fontSize * page.height,
        color: color,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        decoration: underline ? TextDecoration.underline : null,
        decorationColor: color,
        fontFamily: fontFamily,
        height: 1.2,
      );

  TextPainter layout(Size page) => TextPainter(
        text: TextSpan(text: text, style: style(page)),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(1, rect.width * page.width));

  /// Rect grown to fit the laid-out text.
  TextItem fitted(Size page) {
    final tp = layout(page);
    final h = tp.height / page.height;
    tp.dispose();
    return copyWith(rect: Rect.fromLTWH(rect.left, rect.top, rect.width, h));
  }
}

class InkItem extends EditItem {
  const InkItem({
    required int id,
    required this.points,
    required this.color,
    required this.width,
    this.highlighter = false,
  }) : super(id);

  final List<Offset> points;
  final Color color;
  final double width; // fraction of page height
  final bool highlighter;

  @override
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var l = points.first.dx, t = points.first.dy, r = l, b = t;
    for (final p in points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  InkItem copyWith({List<Offset>? points, Color? color, double? width}) =>
      InkItem(id: id, points: points ?? this.points, color: color ?? this.color, width: width ?? this.width, highlighter: highlighter);

  @override
  InkItem moved(Offset d) => copyWith(points: [for (final p in points) p + d]);

  @override
  InkItem resized(Rect r) {
    final b = bounds;
    final sx = b.width <= 0 ? 1.0 : r.width / b.width;
    final sy = b.height <= 0 ? 1.0 : r.height / b.height;
    return copyWith(points: [for (final p in points) Offset(r.left + (p.dx - b.left) * sx, r.top + (p.dy - b.top) * sy)]);
  }
}

enum ShapeKind { rect, ellipse, line, arrow, whiteout, check, cross }

class ShapeItem extends EditItem {
  const ShapeItem({
    required int id,
    required this.kind,
    required this.a,
    required this.b,
    required this.stroke,
    required this.width,
    this.fill,
  }) : super(id);

  final ShapeKind kind;
  final Offset a; // start
  final Offset b; // end
  final Color stroke;
  final double width; // fraction of page height
  final Color? fill;

  @override
  Rect get bounds => Rect.fromPoints(a, b);

  ShapeItem copyWith({Offset? a, Offset? b, Color? stroke, double? width, Color? fill, bool clearFill = false}) => ShapeItem(
        id: id,
        kind: kind,
        a: a ?? this.a,
        b: b ?? this.b,
        stroke: stroke ?? this.stroke,
        width: width ?? this.width,
        fill: clearFill ? null : (fill ?? this.fill),
      );

  @override
  ShapeItem moved(Offset d) => copyWith(a: a + d, b: b + d);

  @override
  ShapeItem resized(Rect r) {
    if (kind == ShapeKind.line || kind == ShapeKind.arrow) {
      final o = bounds;
      Offset map(Offset p) => Offset(
            r.left + (o.width == 0 ? 0 : (p.dx - o.left) / o.width * r.width),
            r.top + (o.height == 0 ? 0 : (p.dy - o.top) / o.height * r.height),
          );
      return copyWith(a: map(a), b: map(b));
    }
    return copyWith(a: r.topLeft, b: r.bottomRight);
  }
}

class ImageItem extends EditItem {
  const ImageItem({required int id, required this.image, required this.bytes, required this.rect, this.opacity = 1})
      : super(id);

  final ui.Image image;
  final Uint8List bytes;
  final Rect rect;
  final double opacity;

  @override
  Rect get bounds => rect;

  ImageItem copyWith({Rect? rect, double? opacity}) =>
      ImageItem(id: id, image: image, bytes: bytes, rect: rect ?? this.rect, opacity: opacity ?? this.opacity);

  @override
  ImageItem moved(Offset d) => copyWith(rect: rect.shift(d));

  @override
  ImageItem resized(Rect r) => copyWith(rect: r);
}

// =====================================================================================
// Painting
// =====================================================================================

Rect _px(Rect r, Size s) => Rect.fromLTRB(r.left * s.width, r.top * s.height, r.right * s.width, r.bottom * s.height);
Offset _pt(Offset o, Size s) => Offset(o.dx * s.width, o.dy * s.height);

void paintItem(Canvas canvas, Size size, EditItem item) {
  switch (item) {
    case TextItem():
      final r = _px(item.rect, size);
      if (item.background != null) {
        final pad = item.fontSize * size.height * 0.15;
        canvas.drawRect(r.inflate(pad), Paint()..color = item.background!);
      }
      final tp = item.layout(size);
      tp.paint(canvas, r.topLeft);
      tp.dispose();
    case InkItem():
      if (item.points.isEmpty) return;
      final paint = Paint()
        ..color = item.highlighter ? item.color.withValues(alpha: 0.38) : item.color
        ..strokeWidth = item.width * size.height
        ..style = PaintingStyle.stroke
        ..strokeCap = item.highlighter ? StrokeCap.square : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = item.highlighter ? BlendMode.multiply : BlendMode.srcOver;
      final path = Path()..moveTo(_pt(item.points.first, size).dx, _pt(item.points.first, size).dy);
      if (item.points.length == 1) {
        final p = _pt(item.points.first, size);
        canvas.drawCircle(p, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        return;
      }
      // Smooth with quadratic curves through midpoints.
      for (var i = 1; i < item.points.length - 1; i++) {
        final p = _pt(item.points[i], size);
        final n = _pt(item.points[i + 1], size);
        path.quadraticBezierTo(p.dx, p.dy, (p.dx + n.dx) / 2, (p.dy + n.dy) / 2);
      }
      final last = _pt(item.points.last, size);
      path.lineTo(last.dx, last.dy);
      canvas.drawPath(path, paint);
    case ShapeItem():
      final a = _pt(item.a, size);
      final b = _pt(item.b, size);
      final r = Rect.fromPoints(a, b);
      final sw = item.width * size.height;
      final stroke = Paint()
        ..color = item.stroke
        ..strokeWidth = sw
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      switch (item.kind) {
        case ShapeKind.whiteout:
          canvas.drawRect(r, Paint()..color = item.fill ?? Colors.white);
        case ShapeKind.rect:
          if (item.fill != null) canvas.drawRect(r, Paint()..color = item.fill!);
          canvas.drawRect(r, stroke);
        case ShapeKind.ellipse:
          if (item.fill != null) canvas.drawOval(r, Paint()..color = item.fill!);
          canvas.drawOval(r, stroke);
        case ShapeKind.line:
          canvas.drawLine(a, b, stroke);
        case ShapeKind.arrow:
          canvas.drawLine(a, b, stroke);
          final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
          final head = math.max(sw * 4, 10.0);
          final p = Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(b.dx - head * math.cos(angle - 0.45), b.dy - head * math.sin(angle - 0.45))
            ..lineTo(b.dx - head * math.cos(angle + 0.45), b.dy - head * math.sin(angle + 0.45))
            ..close();
          canvas.drawPath(p, Paint()..color = item.stroke);
        case ShapeKind.check:
          final p = Path()
            ..moveTo(r.left + r.width * 0.12, r.top + r.height * 0.55)
            ..lineTo(r.left + r.width * 0.40, r.top + r.height * 0.85)
            ..lineTo(r.left + r.width * 0.90, r.top + r.height * 0.15);
          canvas.drawPath(p, stroke..strokeWidth = math.max(sw, r.height * 0.12));
        case ShapeKind.cross:
          final w = math.max(sw, r.height * 0.12);
          canvas.drawLine(r.topLeft + Offset(r.width * .15, r.height * .15), r.bottomRight - Offset(r.width * .15, r.height * .15),
              stroke..strokeWidth = w);
          canvas.drawLine(r.topRight + Offset(-r.width * .15, r.height * .15), r.bottomLeft + Offset(r.width * .15, -r.height * .15),
              stroke);
      }
    case ImageItem():
      final dst = _px(item.rect, size);
      final src = Rect.fromLTWH(0, 0, item.image.width.toDouble(), item.image.height.toDouble());
      canvas.drawImageRect(
        item.image,
        src,
        dst,
        Paint()
          ..filterQuality = FilterQuality.high
          ..color = Colors.white.withValues(alpha: item.opacity),
      );
  }
}

class ItemsPainter extends CustomPainter {
  ItemsPainter(this.items, {this.selectedId, this.preview, this.selectionColor = Colors.blue});
  final List<EditItem> items;
  final int? selectedId;
  final EditItem? preview;
  final Color selectionColor;

  static const handleRadius = 11.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final i in items) {
      paintItem(canvas, size, i);
    }
    if (preview != null) paintItem(canvas, size, preview!);
    canvas.restore();
    final sel = items.where((i) => i.id == selectedId).firstOrNull;
    if (sel != null) {
      final r = _px(sel.bounds, size).inflate(6);
      canvas.drawRect(
        r,
        Paint()
          ..color = selectionColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(r.bottomRight, handleRadius, Paint()..color = selectionColor);
      canvas.drawCircle(r.bottomRight, handleRadius - 4, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant ItemsPainter old) =>
      old.items != items || old.selectedId != selectedId || old.preview != preview;
}

/// Renders [items] to a transparent PNG of [w]×[h] pixels (for stamping onto the PDF).
Future<Uint8List> renderItemsPng(List<EditItem> items, int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final size = Size(w.toDouble(), h.toDouble());
  canvas.saveLayer(Offset.zero & size, Paint());
  for (final i in items) {
    paintItem(canvas, size, i);
  }
  canvas.restore();
  final img = await rec.endRecording().toImage(w, h);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}
