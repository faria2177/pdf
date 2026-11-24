import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'scan_image.dart';

/// Rectangle crop with corner and edge handles, plus quick aspect presets.
class CropPage extends StatefulWidget {
  const CropPage({required this.page, super.key});
  final ScanImage page;

  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  ui.Image? _img;
  late Rect _crop = widget.page.crop;
  late int _turns = widget.page.turns;
  int? _handle; // 0..7 corners/edges, 8 = move
  Size _view = Size.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final src = await decodeImageFile(widget.page.path, maxSide: 1600);
    final t = await transformImage(src, _turns, const Rect.fromLTWH(0, 0, 1, 1));
    src.dispose();
    if (!mounted) {
      t.dispose();
      return;
    }
    setState(() {
      _img?.dispose();
      _img = t;
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  List<Offset> _handles(Rect r) => [
        r.topLeft,
        r.topRight,
        r.bottomRight,
        r.bottomLeft,
        r.topCenter,
        r.centerRight,
        r.bottomCenter,
        r.centerLeft,
      ];

  Rect _px(Rect r) => Rect.fromLTRB(r.left * _view.width, r.top * _view.height, r.right * _view.width, r.bottom * _view.height);

  void _start(Offset p) {
    final hs = _handles(_px(_crop));
    for (var i = 0; i < hs.length; i++) {
      if ((hs[i] - p).distance < 28) {
        _handle = i;
        return;
      }
    }
    _handle = _px(_crop).contains(p) ? 8 : null;
  }

  void _update(DragUpdateDetails d) {
    if (_handle == null) return;
    final dx = d.delta.dx / _view.width, dy = d.delta.dy / _view.height;
    var l = _crop.left, t = _crop.top, r = _crop.right, b = _crop.bottom;
    const min = 0.05;
    switch (_handle) {
      case 0:
        l += dx;
        t += dy;
      case 1:
        r += dx;
        t += dy;
      case 2:
        r += dx;
        b += dy;
      case 3:
        l += dx;
        b += dy;
      case 4:
        t += dy;
      case 5:
        r += dx;
      case 6:
        b += dy;
      case 7:
        l += dx;
      case 8:
        final w = r - l, h = b - t;
        l = (l + dx).clamp(0.0, 1 - w);
        t = (t + dy).clamp(0.0, 1 - h);
        r = l + w;
        b = t + h;
    }
    l = l.clamp(0.0, 1.0);
    t = t.clamp(0.0, 1.0);
    r = r.clamp(0.0, 1.0);
    b = b.clamp(0.0, 1.0);
    if (r - l < min || b - t < min) return;
    setState(() => _crop = Rect.fromLTRB(l, t, r, b));
  }

  void _aspect(double? ratio) {
    final img = _img;
    if (img == null) return;
    if (ratio == null) {
      setState(() => _crop = const Rect.fromLTWH(0, 0, 1, 1));
      return;
    }
    // ratio = width / height in pixels
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    var w = iw, h = iw / ratio;
    if (h > ih) {
      h = ih;
      w = ih * ratio;
    }
    final nw = w / iw * 0.94, nh = h / ih * 0.94;
    setState(() => _crop = Rect.fromLTWH((1 - nw) / 2, (1 - nh) / 2, nw, nh));
  }

  void _rotate() {
    // Rotate the crop rect along with the image (clockwise).
    final c = _crop;
    setState(() {
      _turns = (_turns + 1) % 4;
      _crop = Rect.fromLTRB(1 - c.bottom, c.left, 1 - c.top, c.right);
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        foregroundColor: Colors.white,
        title: const Text('Crop & rotate'),
        actions: [
          TextButton(
            onPressed: () {
              widget.page
                ..crop = _crop
                ..turns = _turns
                ..version += 1;
              Navigator.pop(context, true);
            },
            child: const Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: img == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, c) {
                    final aspect = img.width / img.height;
                    var w = c.maxWidth - 48;
                    var h = w / aspect;
                    if (h > c.maxHeight - 48) {
                      h = c.maxHeight - 48;
                      w = h * aspect;
                    }
                    _view = Size(w, h);
                    return Center(
                      child: GestureDetector(
                        onPanStart: (d) => _start(d.localPosition),
                        onPanUpdate: _update,
                        onPanEnd: (_) => _handle = null,
                        child: SizedBox(
                          width: w,
                          height: h,
                          child: CustomPaint(painter: _CropPainter(img, _crop, _handles(_px(_crop)))),
                        ),
                      ),
                    );
                  }),
          ),
          Container(
            color: const Color(0xFF2C2C2E),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    _btn(Icons.rotate_right, 'Rotate', _rotate),
                    _btn(Icons.crop_free, 'Full', () => _aspect(null)),
                    _btn(Icons.crop_portrait, 'A4', () => _aspect(210 / 297)),
                    _btn(Icons.credit_card, 'Card', () => _aspect(85.6 / 54)),
                    _btn(Icons.crop_square, 'Square', () => _aspect(1)),
                    _btn(Icons.crop_16_9, '16:9', () => _aspect(16 / 9)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
        ),
      );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.img, this.crop, this.handles);
  final ui.Image img;
  final Rect crop;
  final List<Offset> handles;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst,
        Paint()..filterQuality = FilterQuality.medium);
    final c = Rect.fromLTRB(crop.left * size.width, crop.top * size.height, crop.right * size.width, crop.bottom * size.height);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(dst)
      ..addRect(c);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.55));
    final line = Paint()
      ..color = const Color(0xFF19C37D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(c, line);
    // rule of thirds
    final thin = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(c.left + c.width * i / 3, c.top), Offset(c.left + c.width * i / 3, c.bottom), thin);
      canvas.drawLine(Offset(c.left, c.top + c.height * i / 3), Offset(c.right, c.top + c.height * i / 3), thin);
    }
    for (final (i, h) in handles.indexed) {
      final r = i < 4 ? 9.0 : 7.0;
      canvas.drawCircle(h, r, Paint()..color = Colors.white);
      canvas.drawCircle(h, r - 2.5, Paint()..color = const Color(0xFF19C37D));
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.img != img || old.crop != crop;
}
