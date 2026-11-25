import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../pages/home_page.dart' show openPdfInViewer;
import '../services/file_service.dart';
import '../services/recent_store.dart';
import '../widgets/dialogs.dart';
import '../widgets/tool_widgets.dart';
import 'crop_page.dart';
import 'image_filters.dart';
import 'scan_image.dart';
import 'scan_service.dart';

enum CardType {
  nid('National ID', 85.6, 54, true),
  license('Driving licence', 85.6, 54, true),
  student('Student / office ID', 85.6, 54, true),
  passport('Passport page', 125, 88, false),
  business('Business card', 90, 54, true),
  custom('Custom size', 85.6, 54, true);

  const CardType(this.label, this.wMm, this.hMm, this.twoSided);
  final String label;
  final double wMm;
  final double hMm;
  final bool twoSided;
}

enum CardLayout { stacked, sideBySide }

enum CardPaper {
  a4('A4', 595.0, 842.0),
  letter('Letter', 612.0, 792.0);

  const CardPaper(this.label, this.w, this.h);
  final String label;
  final double w;
  final double h;
}

const _mmToPt = 72 / 25.4;
const _accent = Color(0xFF19C37D);

/// CamScanner-style ID card copy: scan front and back, both placed at real size on one page.
class IdCardPage extends StatefulWidget {
  const IdCardPage({super.key});

  @override
  State<IdCardPage> createState() => _IdCardPageState();
}

class _IdCardPageState extends State<IdCardPage> {
  CardType _type = CardType.nid;
  double _customW = 85.6, _customH = 54;
  CardLayout _layout = CardLayout.stacked;
  CardPaper _paper = CardPaper.a4;
  // The DocScanner camera already enhances card captures.
  ScanFilter _filter = ScanFilter.original;
  bool _realSize = true;
  bool _rounded = true;
  bool _cutLines = true;
  bool _labels = false;
  bool _watermark = false;
  final _wmText = TextEditingController(text: 'For verification only');
  Color _wmColor = const Color(0xFFD32F2F);
  double _wmOpacity = 0.35;

  ScanImage? _front;
  ScanImage? _back;
  final _rendered = <ScanImage, (int, ScanFilter, ui.Image)>{};
  ui.Image? _preview;
  bool _previewBusy = false;
  bool _previewDirty = false;
  bool _saved = false;
  final _garbage = <ui.Image>[];

  @override
  void dispose() {
    _wmText.dispose();
    _preview?.dispose();
    for (final r in _rendered.values) {
      r.$3.dispose();
    }
    for (final g in _garbage) {
      g.dispose();
    }
    if (!_saved) ScanService.deleteQuietly([?_front?.path, ?_back?.path]);
    super.dispose();
  }

  bool get _twoSided => _type.twoSided;
  double get _cardW => (_type == CardType.custom ? _customW : _type.wMm) * _mmToPt;
  double get _cardH => (_type == CardType.custom ? _customH : _type.hMm) * _mmToPt;

  // ------------------------------------------------------------------ capture

  IdCardTemplate get _template => switch (_type) {
        CardType.license => IdCardTemplate.driverLicense,
        CardType.passport => IdCardTemplate.passport,
        _ => IdCardTemplate.idCard,
      };

  /// DocScanner card camera: card frame guide, live four-corner detection,
  /// Front then Back in one session when both sides are still missing.
  Future<void> _capture(bool front) async {
    final both = front && _twoSided && _back == null;
    final shots = await ScanService.scanCard(
      context,
      template: _template,
      sides: both ? 2 : 1,
      side: front ? (_twoSided ? 'Front' : _template.firstSide) : 'Back',
    );
    if (shots.isEmpty || !mounted) return;
    // Cards sit landscape on the page; a card photographed sideways comes
    // back portrait, so turn it instead of cropping half of it away.
    final turns = [for (final s in shots) await _landscapeTurns(s)];
    if (!mounted) return;
    setState(() {
      if (front) {
        if (_front != null) ScanService.deleteQuietly([_front!.path]);
        _front = ScanImage(shots[0], filter: _filter, turns: turns[0]);
        if (both && shots.length > 1) {
          _back = ScanImage(shots[1], filter: _filter, turns: turns[1]);
        }
      } else {
        if (_back != null) ScanService.deleteQuietly([_back!.path]);
        _back = ScanImage(shots[0], filter: _filter, turns: turns[0]);
      }
    });
    _refresh();
    if (front && both && shots.length == 1 && _back == null && mounted) {
      final next = await confirm(context, 'Now scan the back side?', ok: 'Scan back', title: 'Front captured');
      if (next && mounted) await _capture(false);
    }
  }

  /// 1 quarter turn when the cropped card is portrait but the card type is
  /// landscape, else 0.
  Future<int> _landscapeTurns(String path) async {
    if (_cardH > _cardW) return 0;
    try {
      final im = await decodeImageFile(path, maxSide: 96);
      final portrait = im.height > im.width * 1.15;
      im.dispose();
      return portrait ? 1 : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _sideMenu(bool front) async {
    final s = front ? _front : _back;
    if (s == null) return _capture(front);
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.camera_alt_outlined), title: const Text('Retake'), onTap: () => Navigator.pop(sheet, 'retake')),
            ListTile(leading: const Icon(Icons.crop), title: const Text('Crop & rotate'), onTap: () => Navigator.pop(sheet, 'crop')),
            ListTile(leading: const Icon(Icons.rotate_right), title: const Text('Rotate 90°'), onTap: () => Navigator.pop(sheet, 'rotate')),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (v) {
      case 'retake':
        await _capture(front);
      case 'crop':
        final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => CropPage(page: s)));
        if (ok == true) _refresh();
      case 'rotate':
        final c = s.crop;
        s
          ..crop = Rect.fromLTRB(1 - c.bottom, c.left, 1 - c.top, c.right)
          ..turns = (s.turns + 1) % 4
          ..version += 1;
        _refresh();
      case 'remove':
        ScanService.deleteQuietly([s.path]);
        setState(() {
          if (front) {
            _front = null;
          } else {
            _back = null;
          }
        });
        _refresh();
    }
  }

  // ------------------------------------------------------------------ compose

  Future<ui.Image?> _sideImage(ScanImage? s) async {
    if (s == null) return null;
    final c = _rendered[s];
    if (c != null && c.$1 == s.version && c.$2 == _filter) return c.$3;
    final img = await renderScanImage(s, maxSide: 1800, filter: _filter);
    // Old image may still be on screen this frame; free it when the page closes.
    final old = _rendered[s];
    if (old != null) _garbage.add(old.$3);
    _rendered[s] = (s.version, _filter, img);
    return img;
  }

  /// Page size in points for the current layout.
  (double, double) get _pageSize =>
      _layout == CardLayout.sideBySide && _twoSided ? (_paper.h, _paper.w) : (_paper.w, _paper.h);

  /// Card boxes on the page, in points (front first).
  List<Rect> _slots() {
    final (pw, ph) = _pageSize;
    var cw = _cardW, ch = _cardH;
    if (!_realSize) {
      final maxW = (_layout == CardLayout.sideBySide && _twoSided ? pw / 2 : pw) * 0.82;
      final f = maxW / cw;
      cw *= f;
      ch *= f;
    }
    final slots = <Rect>[];
    if (!_twoSided) {
      slots.add(Rect.fromCenter(center: Offset(pw / 2, ph * 0.3), width: cw, height: ch));
    } else if (_layout == CardLayout.stacked) {
      final gap = math.max(36.0, ch * 0.35);
      final top = ph * 0.28 - (ch + gap) / 2 + ch / 2;
      slots.add(Rect.fromCenter(center: Offset(pw / 2, top), width: cw, height: ch));
      slots.add(Rect.fromCenter(center: Offset(pw / 2, top + ch + gap), width: cw, height: ch));
    } else {
      final gap = math.max(28.0, cw * 0.12);
      final left = (pw - (cw * 2 + gap)) / 2;
      slots.add(Rect.fromLTWH(left, ph * 0.35 - ch / 2, cw, ch));
      slots.add(Rect.fromLTWH(left + cw + gap, ph * 0.35 - ch / 2, cw, ch));
    }

    return slots;
  }

  /// Draws the whole page at [scale] pixels per point.
  Future<ui.Image> _compose(double scale) async {
    final front = await _sideImage(_front);
    final back = _twoSided ? await _sideImage(_back) : null;
    final (pw, ph) = _pageSize;
    final w = (pw * scale).round(), h = (ph * scale).round();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    canvas.drawRect(Rect.fromLTWH(0, 0, pw, ph), Paint()..color = Colors.white);

    final slots = _slots();
    final cw = slots.first.width;

    final radius = _rounded ? 3.18 * _mmToPt * (cw / _cardW) : 0.0;
    final sides = [front, if (_twoSided) back];
    final labels = ['Front', 'Back'];
    for (var i = 0; i < slots.length; i++) {
      final r = slots[i];
      final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
      final img = sides[i];
      canvas.save();
      canvas.clipRRect(rr);
      if (img != null) {
        // cover the card box without distortion
        final iw = img.width.toDouble(), ih = img.height.toDouble();
        final s = math.max(r.width / iw, r.height / ih);
        final sw = r.width / s, sh = r.height / s;
        final src = Rect.fromLTWH((iw - sw) / 2, (ih - sh) / 2, sw, sh);
        canvas.drawImageRect(img, src, r, Paint()..filterQuality = FilterQuality.high);
        if (_watermark && _wmText.text.trim().isNotEmpty) _drawWatermark(canvas, r);
      } else {
        canvas.drawRect(r, Paint()..color = const Color(0xFFF1F3F4));
        final tp = TextPainter(
          text: TextSpan(
            text: 'Tap to scan ${labels[i].toLowerCase()}',
            style: TextStyle(color: Colors.black38, fontSize: r.height * 0.1),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
        tp.dispose();
      }
      canvas.restore();
      if (_cutLines || img == null) {
        final p = Path()..addRRect(rr.inflate(2));
        _dashed(canvas, p, Paint()
          ..color = Colors.black45
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6);
      }
      if (_labels && _twoSided) {
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: const TextStyle(color: Colors.black54, fontSize: 8)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(r.center.dx - tp.width / 2, r.bottom + 6));
        tp.dispose();
      }
    }
    return rec.endRecording().toImage(w, h);
  }

  void _drawWatermark(Canvas canvas, Rect r) {
    final fs = r.height * 0.11;
    final tp = TextPainter(
      text: TextSpan(
        text: _wmText.text.trim(),
        style: TextStyle(
          color: _wmColor.withValues(alpha: _wmOpacity),
          fontSize: fs,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(r.center.dx, r.center.dy);
    canvas.rotate(-math.pi / 9);
    final stepX = tp.width + fs * 2, stepY = fs * 3;
    final span = math.max(r.width, r.height) * 1.2;
    for (var y = -span / 2; y < span / 2; y += stepY) {
      final shift = ((y / stepY).round().isOdd) ? stepX / 2 : 0;
      for (var x = -span / 2 - shift; x < span / 2; x += stepX) {
        tp.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
    tp.dispose();
  }

  void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), paint);
        d += 7;
      }
    }
  }

  Future<void> _refresh() async {
    if (_previewBusy) {
      _previewDirty = true;
      return;
    }
    _previewBusy = true;
    try {
      do {
        _previewDirty = false;
        final img = await _compose(1.4);
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _preview?.dispose();
          _preview = img;
        });
      } while (_previewDirty && mounted);
    } finally {
      _previewBusy = false;
    }
  }

  void _set(VoidCallback f) {
    setState(f);
    _refresh();
  }

  // ------------------------------------------------------------------ export

  String get _baseName {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${_type.label} ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}';
  }

  Future<void> _export(String how) async {
    if (_front == null) {
      toast(context, 'Scan the front side first');
      return;
    }
    final (pw, ph) = _pageSize;
    final out = await runWithProgress(context, 'Creating copy', (update) async {
      update('Rendering at 300 dpi…', null);
      final page = await _compose(300 / 72);
      final jpg = await imageToJpeg(page, 90);
      page.dispose();
      if (how == 'jpg') return (jpg, '${FileService.safeName(_baseName)}.jpg');
      update('Writing PDF…', null);
      final doc = await PdfDocument.createFromJpegData(jpg, width: pw, height: ph, sourceName: 'id.pdf');
      try {
        final out = await PdfDocument.createNew(sourceName: 'id_out.pdf');
        try {
          out.pages = [doc.pages.first];
          return (await out.encodePdf(), '${FileService.safeName(_baseName)}.pdf');
        } finally {
          await out.dispose();
        }
      } finally {
        await doc.dispose();
      }
    });
    if (out == null || !mounted) return;
    final (bytes, name) = out;
    final r = await RecentStore.instance.addBytes(bytes, name);
    _saved = true;
    if (!mounted) return;
    if (how == 'share') {
      await FileService.shareBytes([(bytes, name)], mimeType: FileService.mimeFor(name));
    } else if (how == 'jpg') {
      final ok = await FileService.saveAs(bytes, name, mimeType: 'image/jpeg');
      if (ok && mounted) toast(context, 'Saved $name');
    } else {
      final nav = Navigator.of(context);
      nav.pop();
      await openPdfInViewer(nav.context, r.path, name: r.name);
    }
  }

  // ------------------------------------------------------------------ UI

  /// A tap on the page preview: the card under the finger opens its menu
  /// (retake, crop, rotate, remove), or scans that side if it is empty.
  void _tapPreview(Offset pos, Size size) {
    final (pw, ph) = _pageSize;
    final pt = Offset(pos.dx / size.width * pw, pos.dy / size.height * ph);
    final slots = _slots();
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].inflate(10).contains(pt)) {
        _sideMenu(i == 0);
        return;
      }
    }
    // Outside the cards: scan whatever is still missing.
    if (_front == null) {
      _capture(true);
    } else if (_twoSided && _back == null) {
      _capture(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (pw, ph) = _pageSize;
    return PopScope(
      canPop: _saved || _front == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirm(context, 'Discard the scanned card?', ok: 'Discard', title: 'Leave?') && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ID Card'),
          actions: [
            IconButton(
              tooltip: 'Card type, layout, filter, page & watermark',
              icon: const Icon(Icons.settings),
              onPressed: _openSettings,
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              // Live page preview
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: pw / ph,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: _preview == null
                          ? Center(child: TextButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: const Text('Preview')))
                          : LayoutBuilder(
                              builder: (context, box) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (d) => _tapPreview(d.localPosition, box.biggest),
                                child: RawImage(image: _preview, fit: BoxFit.contain),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.touch_app_outlined, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _front == null ? 'Tap the card to scan it' : 'Tap a card to retake, crop, rotate or remove it',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: 'Share',
                    onPressed: _front == null ? null : () => _export('share'),
                    icon: const Icon(Icons.share_outlined),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _front == null ? null : () => _export('jpg'),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('JPG', maxLines: 1, softWrap: false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _front == null ? () => _capture(true) : () => _export('pdf'),
                      icon: Icon(_front == null ? Icons.document_scanner : Icons.picture_as_pdf),
                      label: Text(_front == null ? 'Scan front' : 'Save PDF', maxLines: 1, softWrap: false),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Rebuilds the page (and the open settings sheet) after a change.
  void _sset(StateSetter sheetSet, VoidCallback change, {bool refresh = true}) {
    if (refresh) {
      _set(change);
    } else {
      setState(change);
    }
    sheetSet(() {});
  }

  /// Card type, layout, filter, page and watermark live in a sheet so the
  /// page preview gets the whole screen.
  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .62,
        minChildSize: .35,
        maxChildSize: .95,
        builder: (context, controller) => StatefulBuilder(
          builder: (context, sheetSet) {
            final scheme = Theme.of(context).colorScheme;
            return ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
              children: [
                const SectionTitle('Card type'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in CardType.values)
                      ChoiceChip(
                        label: Text(t.label),
                        selected: _type == t,
                        onSelected: (_) => _sset(sheetSet, () => _type = t),
                      ),
                  ],
                ),
                if (_type == CardType.custom) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: _customW.toString(),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Width', suffixText: 'mm', border: OutlineInputBorder(), isDense: true),
                          onChanged: (v) => _sset(sheetSet, () => _customW = (double.tryParse(v) ?? _customW).clamp(20.0, 200.0)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          initialValue: _customH.toString(),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Height', suffixText: 'mm', border: OutlineInputBorder(), isDense: true),
                          onChanged: (v) => _sset(sheetSet, () => _customH = (double.tryParse(v) ?? _customH).clamp(20.0, 200.0)),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_twoSided) ...[
                  const SectionTitle('Layout'),
                  SegmentedButton<CardLayout>(
                    segments: const [
                      ButtonSegment(value: CardLayout.stacked, label: Text('Top & bottom'), icon: Icon(Icons.view_agenda_outlined)),
                      ButtonSegment(value: CardLayout.sideBySide, label: Text('Side by side'), icon: Icon(Icons.view_column_outlined)),
                    ],
                    selected: {_layout},
                    onSelectionChanged: (s) => _sset(sheetSet, () => _layout = s.first),
                  ),
                ],
                const SectionTitle('Filter'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final f in const [ScanFilter.original, ScanFilter.enhance, ScanFilter.magic, ScanFilter.gray, ScanFilter.bw])
                      ChoiceChip(label: Text(f.label), selected: _filter == f, onSelected: (_) => _sset(sheetSet, () => _filter = f)),
                  ],
                ),
                const SectionTitle('Page'),
                Row(
                  children: [
                    for (final p in CardPaper.values) ...[
                      ChoiceChip(label: Text(p.label), selected: _paper == p, onSelected: (_) => _sset(sheetSet, () => _paper = p)),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Actual size'),
                  subtitle: Text(_realSize
                      ? 'Prints at the real card size (${(_cardW / _mmToPt).toStringAsFixed(1)} × ${(_cardH / _mmToPt).toStringAsFixed(1)} mm)'
                      : 'Enlarged to fill the page width — easier to read'),
                  value: _realSize,
                  onChanged: (v) => _sset(sheetSet, () => _realSize = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Rounded corners'),
                  value: _rounded,
                  onChanged: (v) => _sset(sheetSet, () => _rounded = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cut lines'),
                  subtitle: const Text('Dashed outline to cut along'),
                  value: _cutLines,
                  onChanged: (v) => _sset(sheetSet, () => _cutLines = v),
                ),
                if (_twoSided)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Front / Back labels'),
                    value: _labels,
                    onChanged: (v) => _sset(sheetSet, () => _labels = v),
                  ),
                const SectionTitle('Watermark'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Add watermark'),
                  subtitle: const Text('Protects your copy from misuse'),
                  value: _watermark,
                  onChanged: (v) => _sset(sheetSet, () => _watermark = v),
                ),
                if (_watermark) ...[
                  TextField(
                    controller: _wmText,
                    decoration: const InputDecoration(labelText: 'Watermark text', border: OutlineInputBorder(), isDense: true),
                    onChanged: (_) => _sset(sheetSet, () {}),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final t in const ['For verification only', 'Copy', 'Only for bank use', 'শুধুমাত্র যাচাইয়ের জন্য'])
                        ActionChip(
                          label: Text(t, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            _wmText.text = t;
                            _sset(sheetSet, () {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final c in const [Color(0xFFD32F2F), Color(0xFF1565C0), Color(0xFF424242), Color(0xFF2E7D32)])
                        GestureDetector(
                          onTap: () => _sset(sheetSet, () => _wmColor = c),
                          child: Container(
                            margin: const EdgeInsets.only(right: 10),
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(color: c == _wmColor ? scheme.primary : Colors.transparent, width: 3),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Slider(
                          value: _wmOpacity,
                          min: 0.15,
                          max: 0.8,
                          onChanged: (v) => _sset(sheetSet, () => _wmOpacity = v, refresh: false),
                          onChangeEnd: (_) => _refresh(),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
    _refresh();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _capture(true);
    });
  }
}
