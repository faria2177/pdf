import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/home_page.dart' show openPdfInViewer;
import '../pages/tools/ocr_page.dart';
import '../services/file_service.dart';
import '../services/recent_store.dart';
import '../widgets/dialogs.dart';
import '../widgets/tool_widgets.dart';
import 'crop_page.dart';
import 'image_filters.dart';
import 'scan_image.dart';
import 'scan_service.dart';

enum PaperSize {
  auto('Fit to image', null, null),
  a4('A4', 595.0, 842.0),
  letter('Letter', 612.0, 792.0),
  legal('Legal', 612.0, 1008.0);

  const PaperSize(this.label, this.w, this.h);
  final String label;
  final double? w;
  final double? h;
}

enum ScanQuality {
  small('Small', 'Email & WhatsApp', 1600, 70, 150),
  balanced('Balanced', 'Recommended', 2200, 82, 200),
  high('High', 'Print & archive', 3200, 92, 300);

  const ScanQuality(this.label, this.hint, this.maxSide, this.jpeg, this.dpi);
  final String label;
  final String hint;
  final int maxSide;
  final int jpeg;
  final int dpi;
}

class _Cached {
  _Cached(this.version, this.filter, this.image);
  final int version;
  final ScanFilter filter;
  final ui.Image image;
}

/// CamScanner-style review screen after capturing pages.
class ScanReviewPage extends StatefulWidget {
  const ScanReviewPage({required this.images, super.key});
  final List<String> images;

  @override
  State<ScanReviewPage> createState() => _ScanReviewPageState();
}

class _ScanReviewPageState extends State<ScanReviewPage> {
  final _pages = <ScanImage>[];
  final _pageCtrl = PageController();
  int _index = 0;
  late String _name = _defaultName();
  ScanFilter _defaultFilter = ScanFilter.magic;

  final _previews = <ScanImage, _Cached>{};
  final _thumbs = <ScanImage, Map<ScanFilter, _Cached>>{};
  final _busy = <ScanImage>{};
  bool _saved = false;
  bool _discard = false;

  PaperSize _paper = PaperSize.a4;
  ScanQuality _quality = ScanQuality.balanced;
  bool _margins = false;

  static String _defaultName() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}';
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _defaultFilter = ScanFilter.values.firstWhere(
      (f) => f.name == prefs.getString('scan_filter'),
      orElse: () => ScanFilter.magic,
    );
    _paper = PaperSize.values.firstWhere((p) => p.name == prefs.getString('scan_paper'), orElse: () => PaperSize.a4);
    _quality =
        ScanQuality.values.firstWhere((q) => q.name == prefs.getString('scan_quality'), orElse: () => ScanQuality.balanced);
    setState(() => _pages.addAll(widget.images.map((p) => ScanImage(p, filter: _defaultFilter))));
    _warm();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    for (final c in _previews.values) {
      c.image.dispose();
    }
    for (final m in _thumbs.values) {
      for (final c in m.values) {
        c.image.dispose();
      }
    }
    if (!_saved || _discard) ScanService.deleteQuietly(_pages.map((p) => p.path));
    super.dispose();
  }

  ScanImage? get _current => _pages.isEmpty ? null : _pages[_index.clamp(0, _pages.length - 1)];

  // ------------------------------------------------------------------ preview cache

  void _warm() {
    for (final i in [_index, _index + 1, _index - 1]) {
      if (i >= 0 && i < _pages.length) _preview(_pages[i]);
    }
    final c = _current;
    if (c != null) _filterThumbs(c);
  }

  Future<void> _preview(ScanImage s) async {
    final c = _previews[s];
    if (c != null && c.version == s.version && c.filter == s.filter) return;
    if (_busy.contains(s)) return;
    _busy.add(s);
    try {
      final version = s.version, filter = s.filter;
      final img = await renderScanImage(s, maxSide: 1400);
      if (!mounted) {
        img.dispose();
        return;
      }
      final old = _previews[s];
      setState(() => _previews[s] = _Cached(version, filter, img));
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.image.dispose());
    } catch (_) {
    } finally {
      _busy.remove(s);
      // An edit may have happened while we were rendering.
      final c2 = _previews[s];
      if (mounted && _pages.contains(s) && (c2 == null || c2.version != s.version || c2.filter != s.filter)) {
        _preview(s);
      }
    }
  }

  Future<void> _filterThumbs(ScanImage s) async {
    final map = _thumbs.putIfAbsent(s, () => {});
    if (map.values.isNotEmpty && map.values.first.version == s.version) return;
    final old = [...map.values];
    map.clear();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final o in old) {
        o.image.dispose();
      }
    });
    final version = s.version;
    // Render the small base once, then filter it for each option.
    final src = await decodeImageFile(s.path, maxSide: 260);
    final t = await transformImage(src, s.turns, s.crop);
    src.dispose();
    final rgba = await imageToRgba(t);
    final w = t.width, h = t.height;
    t.dispose();
    for (final f in ScanFilter.values) {
      if (!mounted || s.version != version) return;
      final out = f == ScanFilter.original ? rgba : applyScanFilter((rgba, w, h, f.index));
      final img = await rgbaToImage(out, w, h);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => map[f] = _Cached(version, f, img));
    }
  }

  void _edited(ScanImage s) {
    s.version++;
    _preview(s);
    _filterThumbs(s);
    setState(() {});
  }

  // ------------------------------------------------------------------ actions

  Future<void> _setFilter(ScanFilter f, {bool all = false}) async {
    final targets = all ? _pages : [_current!];
    for (final s in targets) {
      s.filter = f;
      _preview(s);
    }
    setState(() {});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scan_filter', f.name);
    _defaultFilter = f;
    if (all && mounted) toast(context, '${f.label} applied to all ${_pages.length} pages');
  }

  void _rotate(int dir) {
    final s = _current;
    if (s == null) return;
    final c = s.crop;
    if (dir > 0) {
      s.crop = Rect.fromLTRB(1 - c.bottom, c.left, 1 - c.top, c.right);
      s.turns = (s.turns + 1) % 4;
    } else {
      s.crop = Rect.fromLTRB(c.top, 1 - c.right, c.bottom, 1 - c.left);
      s.turns = (s.turns + 3) % 4;
    }
    _edited(s);
  }

  Future<void> _crop() async {
    final s = _current;
    if (s == null) return;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => CropPage(page: s)));
    if (ok == true) _edited(s);
  }

  Future<void> _delete() async {
    final s = _current;
    if (s == null) return;
    if (_pages.length == 1) {
      if (await confirm(context, 'Discard this scan?', ok: 'Discard') && mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _pages.remove(s);
      _previews.remove(s)?.image.dispose();
      _thumbs.remove(s)?.values.forEach((c) => c.image.dispose());
      _index = _index.clamp(0, _pages.length - 1);
    });
    ScanService.deleteQuietly([s.path]);
    _warm();
  }

  Future<void> _addPages() async {
    try {
      final more = await ScanService.capture();
      if (more.isEmpty || !mounted) return;
      final start = _pages.length;
      setState(() => _pages.addAll(more.map((p) => ScanImage(p, filter: _defaultFilter))));
      _pageCtrl.jumpToPage(start);
    } catch (e) {
      if (mounted) toast(context, 'Scanner unavailable: $e');
    }
  }

  Future<void> _retake() async {
    final s = _current;
    if (s == null) return;
    try {
      final shot = await ScanService.capture(pageLimit: 1);
      if (shot.isEmpty || !mounted) return;
      ScanService.deleteQuietly([s.path]);
      s
        ..path = shot.first
        ..turns = 0
        ..crop = const Rect.fromLTWH(0, 0, 1, 1);
      _edited(s);
    } catch (e) {
      if (mounted) toast(context, 'Scanner unavailable: $e');
    }
  }

  Future<void> _reorder() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.75,
          child: Column(
            children: [
              const Text('Drag to reorder', style: TextStyle(fontWeight: FontWeight.w600)),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: _pages.length,
                  onReorder: (a, b) {
                    if (b > a) b--;
                    final s = _pages.removeAt(a);
                    _pages.insert(b, s);
                    setSheet(() {});
                    setState(() {});
                  },
                  itemBuilder: (_, i) {
                    final s = _pages[i];
                    final img = _previews[s]?.image;
                    return ListTile(
                      key: ObjectKey(s),
                      leading: SizedBox(
                        width: 44,
                        height: 58,
                        child: img == null ? const Icon(Icons.image_outlined) : RawImage(image: img, fit: BoxFit.contain),
                      ),
                      title: Text('Page ${i + 1}'),
                      subtitle: Text(s.filter.label),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) {
      _pageCtrl.jumpToPage(_index.clamp(0, _pages.length - 1));
      _warm();
    }
  }

  Future<void> _rename() async {
    final v = await askText(context, title: 'Document name', initial: _name, okLabel: 'Save');
    if (v != null && v.trim().isNotEmpty) setState(() => _name = v.trim());
  }

  // ------------------------------------------------------------------ export

  Future<Uint8List> _pageJpeg(ScanImage s, ProgressUpdate update, int n) async {
    final (rgba, w, h) = await renderScan(s, maxSide: _quality.maxSide);
    return rgbaToJpeg(rgba, w, h, _quality.jpeg);
  }

  Future<Uint8List> _buildPdf(ProgressUpdate update) async {
    final docs = <PdfDocument>[];
    try {
      for (var i = 0; i < _pages.length; i++) {
        update('Processing page ${i + 1} of ${_pages.length}', (i + 1) / _pages.length * 0.9);
        final (rgba, w, h) = await renderScan(_pages[i], maxSide: _quality.maxSide);
        Uint8List jpeg;
        double pw, ph;
        if (_paper == PaperSize.auto) {
          pw = w > h ? 842 : 595;
          ph = pw * h / w;
          jpeg = await rgbaToJpeg(rgba, w, h, _quality.jpeg);
        } else {
          final landscape = w > h;
          pw = landscape ? _paper.h! : _paper.w!;
          ph = landscape ? _paper.w! : _paper.h!;
          final scale = _quality.dpi / 72;
          final cw = (pw * scale).round(), ch = (ph * scale).round();
          final margin = _margins ? 28 * scale : 0.0;
          final img = await rgbaToImage(rgba, w, h);
          final rec = ui.PictureRecorder();
          final canvas = Canvas(rec);
          canvas.drawRect(Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), Paint()..color = Colors.white);
          final boxW = cw - margin * 2, boxH = ch - margin * 2;
          final s = (boxW / w) < (boxH / h) ? boxW / w : boxH / h;
          final dw = w * s, dh = h * s;
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            Rect.fromLTWH((cw - dw) / 2, (ch - dh) / 2, dw, dh),
            Paint()..filterQuality = FilterQuality.high,
          );
          img.dispose();
          final page = await rec.endRecording().toImage(cw, ch);
          jpeg = await imageToJpeg(page, _quality.jpeg);
          page.dispose();
        }
        docs.add(await PdfDocument.createFromJpegData(jpeg, width: pw, height: ph, sourceName: 'scan_$i'));
      }
      update('Writing PDF…', null);
      final out = await PdfDocument.createNew(sourceName: '$_name.pdf');
      try {
        out.pages = [for (final d in docs) d.pages.first];
        return await out.encodePdf();
      } finally {
        await out.dispose();
      }
    } finally {
      for (final d in docs) {
        await d.dispose();
      }
    }
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scan_paper', _paper.name);
    await prefs.setString('scan_quality', _quality.name);
  }

  Future<void> _savePdf({bool ocr = false, bool share = false}) async {
    await _savePrefs();
    if (!mounted) return;
    final bytes = await runWithProgress(context, 'Creating PDF', _buildPdf);
    if (bytes == null || !mounted) return;
    final fileName = '${FileService.safeName(_name)}.pdf';
    final r = await RecentStore.instance.addBytes(bytes, fileName);
    _saved = true;
    ScanService.deleteQuietly(_pages.map((p) => p.path));
    if (!mounted) return;
    if (share) await FileService.shareBytes([(bytes, fileName)]);
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    if (ocr) {
      await nav.push(MaterialPageRoute(builder: (_) => OcrPage(path: r.path, name: r.name)));
    } else if (!share) {
      await openPdfInViewer(nav.context, r.path, name: r.name);
    }
  }

  Future<void> _saveJpgs() async {
    await _savePrefs();
    if (!mounted) return;
    final files = await runWithProgress(context, 'Saving images', (update) async {
      final out = <(Uint8List, String)>[];
      for (var i = 0; i < _pages.length; i++) {
        update('Page ${i + 1} of ${_pages.length}', (i + 1) / _pages.length);
        final jpg = await _pageJpeg(_pages[i], update, i);
        final name = _pages.length == 1 ? '${FileService.safeName(_name)}.jpg' : '${FileService.safeName(_name)}_${i + 1}.jpg';
        await RecentStore.instance.addBytes(jpg, name);
        out.add((jpg, name));
      }
      return out;
    });
    if (files == null || !mounted) return;
    _saved = true;
    toast(context, '${files.length} image${files.length == 1 ? '' : 's'} added to Recent');
    await FileService.shareBytes(files, mimeType: 'image/jpeg');
  }

  Future<void> _exportSheet() async {
    var ocr = false;
    final nameCtrl = TextEditingController(text: _name);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Save ${_pages.length} page${_pages.length == 1 ? '' : 's'}', style: Theme.of(sheet).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'File name', border: OutlineInputBorder(), suffixText: '.pdf'),
                ),
                const SectionTitle('Page size'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in PaperSize.values)
                      ChoiceChip(label: Text(p.label), selected: _paper == p, onSelected: (_) => setSheet(() => _paper = p)),
                  ],
                ),
                if (_paper != PaperSize.auto)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('White margins'),
                    value: _margins,
                    onChanged: (v) => setSheet(() => _margins = v),
                  ),
                const SectionTitle('Quality'),
                SegmentedButton<ScanQuality>(
                  segments: [
                    for (final q in ScanQuality.values)
                      ButtonSegment(value: q, label: Text('${q.label}\n${q.hint}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11))),
                  ],
                  selected: {_quality},
                  onSelectionChanged: (s) => setSheet(() => _quality = s.first),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Make text searchable (OCR)'),
                  subtitle: const Text('Recognize text after saving — Bengali, English and more'),
                  value: ocr,
                  onChanged: (v) => setSheet(() => ocr = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(sheet, 'jpg'),
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('JPG'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(sheet, 'share'),
                        icon: const Icon(Icons.share),
                        label: const Text('Share'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(sheet, 'pdf'),
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('Save PDF'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (nameCtrl.text.trim().isNotEmpty) _name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (!mounted) return;
    setState(() {});
    switch (action) {
      case 'pdf':
        await _savePdf(ocr: ocr);
      case 'share':
        await _savePdf(share: true);
      case 'jpg':
        await _saveJpgs();
    }
  }

  // ------------------------------------------------------------------ UI

  Widget _tool(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 62,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(height: 3),
                Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11), maxLines: 1),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1C1C1E);
    const panel = Color(0xFF2C2C2E);
    const accent = Color(0xFF19C37D);
    final cur = _current;
    final thumbs = cur == null ? null : _thumbs[cur];
    return PopScope(
      canPop: _saved || _pages.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirm(context, 'Discard ${_pages.length} scanned page(s)?', ok: 'Discard', title: 'Leave scan?') &&
            context.mounted) {
          setState(() => _saved = true); // allow pop; files are deleted in dispose below
          _discard = true;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          titleSpacing: 0,
          title: InkWell(
            onTap: _rename,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(_name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
                const SizedBox(width: 6),
                const Icon(Icons.edit, size: 16, color: Colors.white70),
              ],
            ),
          ),
          actions: [
            IconButton(tooltip: 'Reorder pages', icon: const Icon(Icons.view_list_outlined), onPressed: _reorder),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white),
                onPressed: _pages.isEmpty ? null : _exportSheet,
                child: const Text('Done'),
              ),
            ),
          ],
        ),
        body: _pages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        PageView.builder(
                          controller: _pageCtrl,
                          itemCount: _pages.length,
                          onPageChanged: (i) {
                            setState(() => _index = i);
                            _warm();
                          },
                          itemBuilder: (_, i) {
                            final s = _pages[i];
                            final c = _previews[s];
                            if (c == null) _preview(s);
                            final stale = c != null && (c.version != s.version || c.filter != s.filter);
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                              child: Center(
                                child: c == null
                                    ? const CircularProgressIndicator(color: accent)
                                    : Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          InteractiveViewer(
                                            maxScale: 5,
                                            child: DecoratedBox(
                                              decoration: const BoxDecoration(
                                                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10)],
                                              ),
                                              child: RawImage(image: c.image, fit: BoxFit.contain),
                                            ),
                                          ),
                                          if (stale) const CircularProgressIndicator(color: accent),
                                        ],
                                      ),
                              ),
                            );
                          },
                        ),
                        Positioned(
                          bottom: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                              child: Text('${_index + 1} / ${_pages.length}', style: const TextStyle(color: Colors.white)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Filter strip
                  Container(
                    color: panel,
                    height: 112,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                      children: [
                        for (final f in ScanFilter.values)
                          GestureDetector(
                            onTap: () => _setFilter(f),
                            onLongPress: () => _setFilter(f, all: true),
                            child: Container(
                              width: 68,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              child: Column(
                                children: [
                                  Container(
                                    width: 64,
                                    height: 70,
                                    decoration: BoxDecoration(
                                      border: Border.all(color: cur?.filter == f ? accent : Colors.transparent, width: 2.5),
                                      borderRadius: BorderRadius.circular(8),
                                      color: Colors.black26,
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: thumbs?[f] == null
                                        ? const Center(
                                            child: SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white38),
                                            ),
                                          )
                                        : RawImage(image: thumbs![f]!.image, fit: BoxFit.cover),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    f.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: cur?.filter == f ? accent : Colors.white70,
                                      fontSize: 11,
                                      fontWeight: cur?.filter == f ? FontWeight.bold : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    color: panel,
                    padding: const EdgeInsets.only(left: 12, bottom: 4),
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: accent, visualDensity: VisualDensity.compact),
                      onPressed: cur == null ? null : () => _setFilter(cur.filter, all: true),
                      icon: const Icon(Icons.done_all, size: 18),
                      label: Text('Apply "${cur?.filter.label ?? ''}" to all pages'),
                    ),
                  ),
                  Container(
                    color: bg,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        children: [
                          _tool(Icons.add_a_photo_outlined, 'Add', _addPages),
                          _tool(Icons.camera_alt_outlined, 'Retake', _retake),
                          _tool(Icons.crop, 'Crop', _crop),
                          _tool(Icons.rotate_left, 'Left', () => _rotate(-1)),
                          _tool(Icons.rotate_right, 'Right', () => _rotate(1)),
                          _tool(Icons.swap_vert, 'Reorder', _reorder),
                          _tool(Icons.delete_outline, 'Delete', _delete),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
