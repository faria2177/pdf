import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../widgets/dialogs.dart';
import 'signature_store.dart';

const _inkColors = [Color(0xFF111111), Color(0xFF0B3D91), Color(0xFF1565C0), Color(0xFF7B1FA2)];

/// Create a signature by drawing, typing or importing a photo. Pops with the saved file.
class SignatureCreatorPage extends StatefulWidget {
  const SignatureCreatorPage({this.kind = SignatureKind.signature, super.key});
  final SignatureKind kind;

  @override
  State<SignatureCreatorPage> createState() => _SignatureCreatorPageState();
}

class _SignatureCreatorPageState extends State<SignatureCreatorPage> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  late SignatureKind _kind = widget.kind;
  Color _color = _inkColors.first;

  // draw
  final _strokes = <List<Offset>>[];
  double _thickness = 3.5;
  Size _padSize = Size.zero;

  // type
  final _typed = TextEditingController();
  int _font = 0;
  static const _fonts = [
    ('Handwritten', 'cursive', false, FontWeight.normal),
    ('Elegant', 'serif', true, FontWeight.normal),
    ('Casual', 'casual', false, FontWeight.normal),
    ('Bold', 'sans-serif-condensed', true, FontWeight.bold),
  ];

  // upload
  Uint8List? _photoRgba;
  int _photoW = 0, _photoH = 0;
  Uint8List? _photoPng;
  double _threshold = 170;
  bool _recolor = true;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _typed.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- export helpers

  Future<Uint8List> _picturePng(void Function(Canvas c) draw, int w, int h) async {
    final rec = ui.PictureRecorder();
    draw(Canvas(rec));
    final img = await rec.endRecording().toImage(w, h);
    try {
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    } finally {
      img.dispose();
    }
  }

  Future<Uint8List?> _drawPng() async {
    final pts = [for (final s in _strokes) ...s];
    if (pts.isEmpty) return null;
    var l = pts.first.dx, t = pts.first.dy, r = l, b = t;
    for (final p in pts) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    final pad = _thickness * 2;
    const scale = 3.0;
    final box = Rect.fromLTRB(l - pad, t - pad, r + pad, b + pad);
    final w = (box.width * scale).ceil().clamp(1, 4000);
    final h = (box.height * scale).ceil().clamp(1, 4000);
    return _picturePng((c) {
      c.scale(scale);
      c.translate(-box.left, -box.top);
      _paintStrokes(c, _strokes, _color, _thickness);
    }, w, h);
  }

  Future<Uint8List?> _typePng() async {
    final text = _typed.text.trim();
    if (text.isEmpty) return null;
    final (_, family, italic, weight) = _fonts[_font];
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 140,
          color: _color,
          fontFamily: family,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = 24.0;
    final w = (tp.width + pad * 2).ceil();
    final h = (tp.height + pad * 2).ceil();
    final png = await _picturePng((c) => tp.paint(c, const Offset(pad, pad)), w, h);
    tp.dispose();
    return png;
  }

  Future<void> _pickPhoto() async {
    final files = await FileService.pickImages();
    if (files.isEmpty) return;
    final bytes = await File(files.first.path).readAsBytes();
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buf,
      getTargetSize: (w, h) {
        final s = math.min(1.0, 1600 / math.max(w, h));
        return ui.TargetImageSize(width: (w * s).round(), height: (h * s).round());
      },
    );
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    _photoW = img.width;
    _photoH = img.height;
    img.dispose();
    codec.dispose();
    _photoRgba = rgba;
    await _processPhoto();
  }

  Future<void> _processPhoto() async {
    final src = _photoRgba;
    if (src == null) return;
    final out = await compute(_removeBackground, (src, _threshold.round(), _recolor ? _color.toARGB32() : null));
    final buf = await ui.ImmutableBuffer.fromUint8List(out);
    final desc = ui.ImageDescriptor.raw(buf, width: _photoW, height: _photoH, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    final frame = await codec.getNextFrame();
    final png = (await frame.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    frame.image.dispose();
    codec.dispose();
    desc.dispose();
    if (mounted) setState(() => _photoPng = png);
  }

  Future<void> _save() async {
    final png = switch (_tabs.index) {
      0 => await _drawPng(),
      1 => await _typePng(),
      _ => _photoPng,
    };
    if (png == null) {
      if (mounted) toast(context, 'Create your ${_kind == SignatureKind.initials ? 'initials' : 'signature'} first');
      return;
    }
    final f = await SignatureStore.save(png, _kind);
    if (mounted) Navigator.of(context).pop(f);
  }

  // ------------------------------------------------------------- UI

  Widget _colorRow() => Row(
        children: [
          for (final c in _inkColors)
            GestureDetector(
              onTap: () {
                setState(() => _color = c);
                if (_tabs.index == 2) _processPhoto();
              },
              child: Container(
                margin: const EdgeInsets.only(right: 10),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: c == _color ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 3),
                ),
              ),
            ),
        ],
      );

  Widget _drawTab() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                _padSize = c.biggest;
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: GestureDetector(
                      onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                      onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                      child: CustomPaint(
                        size: _padSize,
                        painter: _StrokesPainter(_strokes, _color, _thickness, _strokes.fold(0, (s, e) => s + e.length)),
                        child: _strokes.isEmpty
                            ? const Center(child: Text('Sign here', style: TextStyle(color: Colors.black26, fontSize: 28)))
                            : null,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _colorRow(),
                const Spacer(),
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo),
                  onPressed: _strokes.isEmpty ? null : () => setState(() => _strokes.removeLast()),
                ),
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(Icons.line_weight, size: 20),
                Expanded(
                  child: Slider(value: _thickness, min: 1.5, max: 8, onChanged: (v) => setState(() => _thickness = v)),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _typeTab() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _typed,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: _kind == SignatureKind.initials ? 'Your initials' : 'Your name',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          _colorRow(),
          const SizedBox(height: 12),
          for (final (i, (label, family, italic, weight)) in _fonts.indexed)
            Card(
              color: i == _font ? Theme.of(context).colorScheme.primaryContainer : Colors.white,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _font = i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _typed.text.trim().isEmpty ? 'Your Name' : _typed.text.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 30,
                            color: _color,
                            fontFamily: family,
                            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                            fontWeight: weight,
                          ),
                        ),
                      ),
                      Text(label, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );

  Widget _uploadTab() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F3F3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            alignment: Alignment.center,
            child: _photoPng == null
                ? TextButton.icon(
                    onPressed: _pickPhoto,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Choose a photo of your signature'),
                  )
                : Padding(padding: const EdgeInsets.all(8), child: Image.memory(_photoPng!, fit: BoxFit.contain)),
          ),
          const SizedBox(height: 8),
          const Text('Sign on white paper, take a photo, and the paper is removed automatically.'),
          if (_photoRgba != null) ...[
            const SizedBox(height: 12),
            const Text('Background removal'),
            Slider(
              value: _threshold,
              min: 80,
              max: 240,
              label: _threshold.round().toString(),
              onChanged: (v) => setState(() => _threshold = v),
              onChangeEnd: (_) => _processPhoto(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Recolor ink'),
              subtitle: _colorRow(),
              value: _recolor,
              onChanged: (v) {
                setState(() => _recolor = v);
                _processPhoto();
              },
            ),
            TextButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo), label: const Text('Choose another photo')),
          ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_kind == SignatureKind.initials ? 'Create initials' : 'Create signature'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.gesture), text: 'Draw'),
            Tab(icon: Icon(Icons.keyboard_outlined), text: 'Type'),
            Tab(icon: Icon(Icons.photo_camera_outlined), text: 'Photo'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<SignatureKind>(
              segments: const [
                ButtonSegment(value: SignatureKind.signature, label: Text('Signature')),
                ButtonSegment(value: SignatureKind.initials, label: Text('Initials')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [_drawTab(), _typeTab(), _uploadTab()],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save & use')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _paintStrokes(Canvas c, List<List<Offset>> strokes, Color color, double width) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (final s in strokes) {
    if (s.isEmpty) continue;
    if (s.length == 1) {
      c.drawCircle(s.first, width / 2, Paint()..color = color);
      continue;
    }
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (var i = 1; i < s.length - 1; i++) {
      final p = s[i], n = s[i + 1];
      path.quadraticBezierTo(p.dx, p.dy, (p.dx + n.dx) / 2, (p.dy + n.dy) / 2);
    }
    path.lineTo(s.last.dx, s.last.dy);
    c.drawPath(path, paint);
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes, this.color, this.width, this.version);
  final List<List<Offset>> strokes;
  final Color color;
  final double width;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline guide
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.72),
      Offset(size.width * 0.92, size.height * 0.72),
      Paint()
        ..color = Colors.black12
        ..strokeWidth = 1.5,
    );
    _paintStrokes(canvas, strokes, color, width);
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) =>
      old.version != version || old.color != color || old.width != width || old.strokes.length != strokes.length;
}

/// Makes light pixels transparent; optionally recolors ink to [ink] (ARGB).
Uint8List _removeBackground((Uint8List, int, int?) a) {
  final (src, threshold, ink) = a;
  final out = Uint8List.fromList(src);
  final ir = ink == null ? 0 : (ink >> 16) & 0xFF;
  final ig = ink == null ? 0 : (ink >> 8) & 0xFF;
  final ib = ink == null ? 0 : ink & 0xFF;
  for (var i = 0; i < out.length; i += 4) {
    final lum = (out[i] * 299 + out[i + 1] * 587 + out[i + 2] * 114) ~/ 1000;
    if (lum >= threshold) {
      out[i + 3] = 0;
    } else {
      // Soft edge: darker = more opaque.
      final alpha = ((threshold - lum) * 255 ~/ math.max(1, threshold ~/ 2)).clamp(0, 255);
      out[i + 3] = alpha;
      if (ink != null) {
        out[i] = ir;
        out[i + 1] = ig;
        out[i + 2] = ib;
      }
    }
  }
  return out;
}
