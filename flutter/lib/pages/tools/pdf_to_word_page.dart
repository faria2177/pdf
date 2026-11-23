import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/file_service.dart';
import '../../utils/office_writers.dart';
import '../../utils/text_layout.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';
import 'tool_base.dart';

enum WordMode { editable, layout, both }

enum WordPageSize { match, a4, letter }

const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

class PdfToWordPage extends StatefulWidget {
  const PdfToWordPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<PdfToWordPage> createState() => _PdfToWordPageState();
}

class _PdfToWordPageState extends PdfToolState<PdfToWordPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  WordMode _mode = WordMode.editable;
  WordPageSize _size = WordPageSize.match;
  PageSelection _pages = const PageSelection.all();
  bool _headings = true;
  bool _pageBreaks = true;
  bool _highQuality = false;
  Uint8List? _result;
  String _stats = '';
  bool _noText = false;

  String get _outName => '${FileService.withoutExtension(widget.name)}.docx';

  Future<Uint8List> _pageJpeg(PdfPage page, double dpi) async {
    final w = (page.width * dpi / 72).round();
    final h = (page.height * dpi / 72).round();
    final r = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xFFFFFFFF);
    if (r == null) throw Exception('Could not render page ${page.pageNumber}');
    try {
      final img = await r.createImage();
      final rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      img.dispose();
      return compute(_jpeg, (rgba, w, h, _highQuality ? 90 : 80));
    } finally {
      r.dispose();
    }
  }

  Future<void> _convert() async {
    final d = doc!;
    final pages = _pages.resolve(pageCount);
    final result = await runWithProgress(context, 'Converting to Word', (update) async {
      final first = d.pages[pages.first - 1];
      final (pw, ph) = switch (_size) {
        WordPageSize.match => (first.width, first.height),
        WordPageSize.a4 => (595.0, 842.0),
        WordPageSize.letter => (612.0, 792.0),
      };
      const margin = 54.0;
      final b = DocxBuilder();
      var paragraphs = 0;
      var words = 0;

      // Body text size across the chosen pages, for heading detection.
      final allLines = <int, List<TextLine>>{};
      if (_mode != WordMode.layout) {
        for (var i = 0; i < pages.length; i++) {
          update('Reading text… page ${pages[i]}', (i + 1) / pages.length * 0.4);
          allLines[pages[i]] = await readingLines(d.pages[pages[i] - 1]);
        }
      }
      final heights = [for (final l in allLines.values) for (final x in l) x.charHeight]..sort();
      final body = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];

      for (var i = 0; i < pages.length; i++) {
        final n = pages[i];
        final page = d.pages[n - 1];
        update('Writing page $n of ${pages.last}', 0.4 + (i + 1) / pages.length * 0.6);
        if (i > 0 && _pageBreaks) b.pageBreak();

        if (_mode != WordMode.editable) {
          final jpeg = await _pageJpeg(page, _highQuality ? 220 : 150);
          final maxW = pw - margin * 2;
          final maxH = ph - margin * 2;
          final s = (maxW / page.width) < (maxH / page.height) ? maxW / page.width : maxH / page.height;
          b.image(jpeg, page.width * s, page.height * s);
          if (_mode == WordMode.both) b.pageBreak();
        }
        if (_mode != WordMode.layout) {
          final paras = paragraphsFromLines(allLines[n] ?? const [], bodyHeight: body > 0 ? body : null);
          for (final p in paras) {
            if (_headings && p.level > 0) {
              b.heading(p.text, p.level);
            } else {
              b.paragraph(p.text);
            }
            paragraphs++;
            words += p.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
          }
        }
      }
      update('Packaging .docx…', null);
      final bytes = b.build(pageWidthPt: pw, pageHeightPt: ph, marginPt: margin, title: FileService.withoutExtension(widget.name));
      return (bytes, paragraphs, words);
    });
    if (result == null || !mounted) return;
    final (bytes, paragraphs, words) = result;
    setState(() {
      _result = bytes;
      _noText = _mode != WordMode.layout && words == 0;
      _stats = '${pages.length} pages'
          '${_mode != WordMode.layout ? ' · $paragraphs paragraphs · $words words' : ''}'
          ' · ${formatBytes(bytes.length)}';
    });
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _result = null;
      });

  @override
  Widget build(BuildContext context) {
    final err = doc == null ? null : _pages.error(pageCount);
    return Scaffold(
      appBar: AppBar(title: const Text('PDF to Word')),
      body: doc == null
          ? loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                header(),
                const SectionTitle('Conversion'),
                ChoiceCards<WordMode>(
                  value: _mode,
                  onChanged: (v) => _changed(() => _mode = v),
                  options: const [
                    (WordMode.editable, Icons.edit_note, 'Editable text',
                        'Text reflowed into paragraphs and headings you can edit in Word'),
                    (WordMode.layout, Icons.image_outlined, 'Exact layout',
                        'Each page as a picture — looks identical, not editable'),
                    (WordMode.both, Icons.layers_outlined, 'Layout + text',
                        'Page picture followed by its editable text'),
                  ],
                ),
                const SectionTitle('Pages'),
                PageRangeSelector(pageCount: pageCount, value: _pages, onChanged: (v) => _changed(() => _pages = v)),
                const SectionTitle('Page size'),
                SegmentedButton<WordPageSize>(
                  segments: const [
                    ButtonSegment(value: WordPageSize.match, label: Text('Same as PDF')),
                    ButtonSegment(value: WordPageSize.a4, label: Text('A4')),
                    ButtonSegment(value: WordPageSize.letter, label: Text('Letter')),
                  ],
                  selected: {_size},
                  onSelectionChanged: (s) => _changed(() => _size = s.first),
                ),
                const SectionTitle('Options'),
                if (_mode != WordMode.layout)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Detect headings'),
                    subtitle: const Text('Larger text becomes Heading 1 / Heading 2 (shows in Word navigation)'),
                    value: _headings,
                    onChanged: (v) => _changed(() => _headings = v),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Page break after each PDF page'),
                  value: _pageBreaks,
                  onChanged: (v) => _changed(() => _pageBreaks = v),
                ),
                if (_mode != WordMode.editable)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('High image quality'),
                    subtitle: const Text('220 dpi instead of 150 dpi — sharper, bigger file'),
                    value: _highQuality,
                    onChanged: (v) => _changed(() => _highQuality = v),
                  ),
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: err == null ? _convert : null,
                    icon: const Icon(Icons.description_outlined),
                    label: Text(err ?? 'Convert to Word'),
                  )
                else ...[
                  if (_noText)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('No text was found — this looks like a scanned PDF. '
                            'Run "OCR PDF" first, or choose "Exact layout".'),
                      ),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: Text(_outName),
                    subtitle: Text(_stats),
                  ),
                  ResultActions(bytes: _result!, fileName: _outName, allowOpen: false, mimeType: docxMime),
                ],
              ],
            ),
    );
  }
}

Uint8List _jpeg((Uint8List, int, int, int) a) {
  final (rgba, w, h, q) = a;
  return JpegEncoder().compress(rgba, w, h, q);
}
