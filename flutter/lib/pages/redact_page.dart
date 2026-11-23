import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../widgets/dialogs.dart';
import '../widgets/result_actions.dart';

/// "Redact a PDF": draw black boxes (or find text) and burn them in.
///
/// Every page that has a box is re-rendered as an image with the boxes painted on, so the
/// hidden text and graphics are really gone from that page — not just covered. Pages without
/// boxes are copied unchanged.
class RedactPage extends StatefulWidget {
  const RedactPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<RedactPage> createState() => _RedactPageState();
}

class _RedactPageState extends State<RedactPage> {
  PdfDocument? _doc;
  int _index = 0;

  /// Boxes per page index, in 0..1 coordinates of the displayed (rotated) page.
  final _boxes = <int, List<Rect>>{};
  final _history = <(int, Rect)>[];
  Offset? _dragStart;
  Rect? _dragRect;
  Uint8List? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final doc = await openPdfDocument(context, widget.path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      setState(() => _doc = doc);
    } catch (e) {
      if (!mounted) return;
      toast(context, "Couldn't open: $e");
      Navigator.of(context).maybePop();
    }
  }

  int get _total => _boxes.values.fold(0, (a, b) => a + b.length);

  void _add(int page, Rect r) {
    setState(() {
      _boxes.putIfAbsent(page, () => []).add(r);
      _history.add((page, r));
      _result = null;
    });
  }

  void _remove(int page, Rect r) {
    setState(() {
      _boxes[page]?.remove(r);
      if (_boxes[page]?.isEmpty ?? false) _boxes.remove(page);
      _history.removeWhere((e) => e.$1 == page && e.$2 == r);
      _result = null;
    });
  }

  void _undo() {
    if (_history.isEmpty) return;
    final (page, r) = _history.last;
    _remove(page, r);
    setState(() => _index = page);
  }

  // ---------------------------------------------------------------- find text

  Future<void> _findText() async {
    final doc = _doc;
    if (doc == null) return;
    final term = await askText(
      context,
      title: 'Redact text',
      hint: 'Name, number, email…',
      helper: 'Every match on every page gets a box. Scanned pages have no text to find.',
      okLabel: 'Find',
    );
    final q = term?.trim().toLowerCase() ?? '';
    if (q.isEmpty || !mounted) return;

    final found = await withProgress(context, 'Searching…', () async {
      final result = <(int, Rect)>[];
      for (var i = 0; i < doc.pages.length; i++) {
        final page = doc.pages[i];
        final raw = await page.loadText();
        if (raw == null) continue;
        final text = raw.fullText.toLowerCase();
        var from = 0;
        while (true) {
          final at = text.indexOf(q, from);
          if (at < 0) break;
          from = at + q.length;
          Rect? box;
          for (var c = at; c < at + q.length && c < raw.charRects.length; c++) {
            final r = raw.charRects[c].toRect(page: page);
            if (r.isEmpty && r.width == 0 && r.height == 0) continue;
            box = box == null ? r : box.expandToInclude(r);
          }
          if (box == null || page.width == 0 || page.height == 0) continue;
          final pad = box.height * 0.15;
          final n = Rect.fromLTRB(
            (box.left - pad) / page.width,
            (box.top - pad) / page.height,
            (box.right + pad) / page.width,
            (box.bottom + pad) / page.height,
          ).intersect(const Rect.fromLTWH(0, 0, 1, 1));
          result.add((i, n));
        }
      }
      return result;
    });
    if (found == null || !mounted) return;
    if (found.isEmpty) {
      toast(context, 'No matches for "$q"');
      return;
    }
    setState(() {
      for (final (p, r) in found) {
        _boxes.putIfAbsent(p, () => []).add(r);
        _history.add((p, r));
      }
      _result = null;
      _index = found.first.$1;
    });
    toast(context, '${found.length} matches marked');
  }

  // ---------------------------------------------------------------- apply

  Future<Uint8List> _burn() async {
    final path = widget.path;
    final dest = await PdfDocument.openFile(path, passwordProvider: () => knownPassword(path));
    final temps = <PdfDocument>[];
    try {
      final pages = [...dest.pages];
      for (final entry in _boxes.entries) {
        final i = entry.key;
        final page = pages[i];
        const dpi = 200.0;
        final w = (page.width * dpi / 72).round();
        final h = (page.height * dpi / 72).round();
        final rendered = await page.render(
          width: w,
          height: h,
          fullWidth: w.toDouble(),
          fullHeight: h.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );
        if (rendered == null) throw Exception('Could not render page ${i + 1}');
        final ui.Image img;
        try {
          img = await rendered.createImage();
        } finally {
          rendered.dispose();
        }
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImage(img, Offset.zero, ui.Paint());
        final black = ui.Paint()..color = const Color(0xFF000000);
        for (final r in entry.value) {
          canvas.drawRect(Rect.fromLTRB(r.left * w, r.top * h, r.right * w, r.bottom * h), black);
        }
        img.dispose();
        final burned = await recorder.endRecording().toImage(w, h);
        final rgba = (await burned.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        burned.dispose();
        final jpeg = await compute(_jpeg, (rgba, w, h));
        final imgDoc = await PdfDocument.createFromJpegData(jpeg,
            width: page.width, height: page.height, sourceName: 'redacted_$i');
        temps.add(imgDoc);
        pages[i] = imgDoc.pages.first;
      }
      dest.pages = pages;
      return await dest.encodePdf();
    } finally {
      await dest.dispose();
      for (final t in temps) {
        await t.dispose();
      }
    }
  }

  Future<void> _apply() async {
    if (_total == 0) {
      toast(context, 'Draw boxes over what you want to hide');
      return;
    }
    final go = await confirm(
      context,
      '${_boxes.length} page(s) will be flattened into images with the marked areas blacked out. '
      'Text on those pages will no longer be selectable or searchable. Your original file is not changed.',
      ok: 'Redact',
      title: 'Apply redaction?',
    );
    if (!go || !mounted) return;
    final bytes = await withProgress(context, 'Redacting ${_boxes.length} page(s)…', _burn);
    if (bytes != null && mounted) setState(() => _result = bytes);
  }

  // ---------------------------------------------------------------- build

  Widget _pageEditor(PdfDocument doc) {
    final page = doc.pages[_index];
    final aspect = page.height == 0 ? 0.7 : page.width / page.height;
    final boxes = _boxes[_index] ?? const <Rect>[];
    return LayoutBuilder(builder: (context, c) {
      var w = c.maxWidth - 16;
      var h = w / aspect;
      if (h > c.maxHeight - 16) {
        h = c.maxHeight - 16;
        w = h * aspect;
      }
      final size = Size(w, h);
      Rect norm(Offset a, Offset b) => Rect.fromPoints(
            Offset((a.dx / w).clamp(0, 1), (a.dy / h).clamp(0, 1)),
            Offset((b.dx / w).clamp(0, 1), (b.dy / h).clamp(0, 1)),
          );
      return Center(
        child: SizedBox.fromSize(
          size: size,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 4)]),
                  child: PdfPageView(
                    key: ValueKey('redact_page_$_index'),
                    document: doc,
                    pageNumber: _index + 1,
                    maximumDpi: 150,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => setState(() {
                    _dragStart = d.localPosition;
                    _dragRect = norm(d.localPosition, d.localPosition);
                  }),
                  onPanUpdate: (d) => setState(() => _dragRect = norm(_dragStart!, d.localPosition)),
                  onPanEnd: (_) {
                    final r = _dragRect;
                    setState(() {
                      _dragStart = null;
                      _dragRect = null;
                    });
                    if (r != null && r.width * w > 6 && r.height * h > 6) _add(_index, r);
                  },
                ),
              ),
              for (final r in boxes)
                Positioned(
                  left: r.left * w,
                  top: r.top * h,
                  width: r.width * w,
                  height: r.height * h,
                  child: GestureDetector(
                    onTap: () => _remove(_index, r),
                    child: Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: r.width * w > 28 && r.height * h > 18
                          ? const Icon(Icons.close, color: Colors.white54, size: 14)
                          : null,
                    ),
                  ),
                ),
              if (_dragRect != null)
                Positioned(
                  left: _dragRect!.left * w,
                  top: _dragRect!.top * h,
                  width: _dragRect!.width * w,
                  height: _dragRect!.height * h,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      border: Border.all(color: Colors.redAccent, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final outName = '${FileService.withoutExtension(widget.name)}_redacted.pdf';
    return PopScope(
      canPop: _total == 0 || _result != null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirm(context, 'Your marked areas will be lost.', ok: 'Discard', title: 'Leave?') &&
            context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Redact a PDF'),
          actions: [
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _history.isEmpty ? null : _undo),
            IconButton(
              tooltip: 'Find text to redact',
              icon: const Icon(Icons.manage_search),
              onPressed: doc == null ? null : _findText,
            ),
            IconButton(
              tooltip: 'Clear this page',
              icon: const Icon(Icons.layers_clear_outlined),
              onPressed: (_boxes[_index]?.isEmpty ?? true)
                  ? null
                  : () => setState(() {
                        _history.removeWhere((e) => e.$1 == _index);
                        _boxes.remove(_index);
                        _result = null;
                      }),
            ),
          ],
        ),
        body: doc == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Drag over anything you want hidden. Tap a box to remove it.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Expanded(child: _pageEditor(doc)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: _index > 0 ? () => setState(() => _index--) : null,
                      ),
                      TextButton(
                        onPressed: () async {
                          final v = await askText(context,
                              title: 'Go to page', hint: '1 – ${doc.pages.length}', keyboardType: TextInputType.number);
                          final n = int.tryParse(v?.trim() ?? '');
                          if (n != null && n >= 1 && n <= doc.pages.length) setState(() => _index = n - 1);
                        },
                        child: Text('Page ${_index + 1} / ${doc.pages.length}'
                            '${(_boxes[_index]?.length ?? 0) > 0 ? '  ·  ${_boxes[_index]!.length} box(es)' : ''}'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: _index < doc.pages.length - 1 ? () => setState(() => _index++) : null,
                      ),
                    ],
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: _result == null
                          ? SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _total == 0 ? null : _apply,
                                icon: const Icon(Icons.format_color_fill),
                                label: Text(_total == 0
                                    ? 'Mark areas to redact'
                                    : 'Redact $_total area(s) on ${_boxes.length} page(s)'),
                              ),
                            )
                          : ResultActions(bytes: _result!, fileName: outName),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

Uint8List _jpeg((Uint8List, int, int) a) {
  final (rgba, w, h) = a;
  return JpegEncoder().compress(rgba, w, h, 90);
}
