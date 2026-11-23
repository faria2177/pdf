import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../services/file_service.dart';
import '../../services/ocr_service.dart';
import '../../utils/office_writers.dart';
import '../../utils/text_layout.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/ocr_language_picker.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';
import 'pdf_to_word_page.dart' show docxMime;
import 'tool_base.dart';

enum TextSource { textLayer, ocr }

enum TextShape { paragraphs, lines }

class ExtractTextPage extends StatefulWidget {
  const ExtractTextPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<ExtractTextPage> createState() => _ExtractTextPageState();
}

class _ExtractTextPageState extends PdfToolState<ExtractTextPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  TextSource _source = TextSource.textLayer;
  TextShape _shape = TextShape.paragraphs;
  PageSelection _pages = const PageSelection.all();
  bool _pageMarkers = true;
  bool _tidySpaces = true;
  List<String> _langs = const ['eng'];
  OcrModel _model = OcrModel.fast;
  bool _cancel = false;

  List<(int, String)>? _result; // (page, text)

  @override
  void initState() {
    super.initState();
    OcrService.loadPrefs().then((p) {
      if (mounted) {
        setState(() {
          _langs = p.$1;
          _model = p.$2;
        });
      }
    });
  }

  String get _base => FileService.withoutExtension(widget.name);

  String _tidy(String s) {
    var t = s;
    if (_tidySpaces) {
      t = t.replaceAll(RegExp(r'[ \t ]+'), ' ').replaceAll(RegExp(r' *\n *'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
    }
    return t.trim();
  }

  String get _fullText {
    final r = _result ?? const [];
    return r
        .map((e) => _pageMarkers ? '--- Page ${e.$1} ---\n${e.$2}' : e.$2)
        .where((t) => t.trim().isNotEmpty)
        .join('\n\n');
  }

  Future<void> _run() async {
    final pages = _pages.resolve(pageCount);
    if (_source == TextSource.ocr) {
      final missing = await OcrService.missing(_langs, _model);
      if (!mounted) return;
      if (missing.isNotEmpty || _langs.isEmpty) {
        toast(context, 'Choose and download an OCR language first.');
        return;
      }
      await OcrService.savePrefs(_langs, _model);
      if (!mounted) return;
    }
    _cancel = false;
    var images = <String>[];
    final out = await runWithProgress<List<(int, String)>>(
      context,
      'Extracting text',
      (update) async {
        final res = <(int, String)>[];
        if (_source == TextSource.textLayer) {
          for (var i = 0; i < pages.length; i++) {
            update('Page ${pages[i]}', (i + 1) / pages.length);
            final page = doc!.pages[pages[i] - 1];
            String text;
            if (_shape == TextShape.paragraphs) {
              final paras = paragraphsFromLines(await readingLines(page));
              text = paras.map((p) => p.text).join('\n\n');
            } else {
              text = (await readingLines(page)).map((l) => l.text).join('\n');
            }
            res.add((pages[i], _tidy(text)));
          }
        } else {
          images = await OcrService.renderPages(doc!, pages, dpi: 300, onProgress: (d, t) {
            update('Preparing page $d of $t', d / t * 0.25);
          });
          if (_cancel) return res;
          final texts = await OcrService.toText(
            images: images,
            languages: _langs,
            model: _model,
            dpi: 300,
            onProgress: (d, t) => update('Reading page $d of $t…', 0.25 + d / t * 0.75),
          );
          for (final (i, t) in texts.indexed) {
            var text = t.text;
            if (_shape == TextShape.paragraphs) {
              text = text
                  .split(RegExp(r'\n\s*\n'))
                  .map((p) => p.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim())
                  .where((p) => p.isNotEmpty)
                  .join('\n\n');
            }
            res.add((pages[i], _tidy(text)));
          }
        }
        return res;
      },
      onCancel: _source == TextSource.ocr
          ? () async {
              _cancel = true;
              await OcrService.cancel();
            }
          : null,
    );
    OcrService.cleanup(images);
    if (out != null && mounted) setState(() => _result = out);
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _result = null;
      });

  @override
  Widget build(BuildContext context) {
    final err = doc == null ? null : _pages.error(pageCount);
    final text = _fullText;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !w.startsWith('---')).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Extract text')),
      body: doc == null
          ? loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                header(),
                const SectionTitle('Source'),
                ChoiceCards<TextSource>(
                  value: _source,
                  onChanged: (v) => _changed(() => _source = v),
                  options: const [
                    (TextSource.textLayer, Icons.text_snippet_outlined, 'Text in the PDF',
                        'Instant and exact — for PDFs made from documents'),
                    (TextSource.ocr, Icons.document_scanner_outlined, 'Recognize with OCR',
                        'For scans and photos — works offline after a one-time download'),
                  ],
                ),
                if (_source == TextSource.ocr) ...[
                  const SectionTitle('OCR language'),
                  OcrLanguagePicker(
                    selected: _langs,
                    model: _model,
                    onChanged: (v) => _changed(() => _langs = v),
                    onModelChanged: (m) => _changed(() => _model = m),
                  ),
                ],
                const SectionTitle('Pages'),
                PageRangeSelector(pageCount: pageCount, value: _pages, onChanged: (v) => _changed(() => _pages = v)),
                const SectionTitle('Formatting'),
                SegmentedButton<TextShape>(
                  segments: const [
                    ButtonSegment(value: TextShape.paragraphs, label: Text('Paragraphs'), icon: Icon(Icons.subject)),
                    ButtonSegment(value: TextShape.lines, label: Text('Original lines'), icon: Icon(Icons.format_align_left)),
                  ],
                  selected: {_shape},
                  onSelectionChanged: (s) => _changed(() => _shape = s.first),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Page markers'),
                  subtitle: const Text('Insert "--- Page N ---" between pages'),
                  value: _pageMarkers,
                  onChanged: (v) => setState(() => _pageMarkers = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tidy spacing'),
                  subtitle: const Text('Collapse repeated spaces and blank lines'),
                  value: _tidySpaces,
                  onChanged: (v) => _changed(() => _tidySpaces = v),
                ),
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: err == null ? _run : null,
                    icon: const Icon(Icons.text_fields),
                    label: Text(err ?? 'Extract text'),
                  )
                else ...[
                  Text('$words words · ${text.length} characters', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 320),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text.isEmpty
                            ? (_source == TextSource.textLayer
                                ? 'No text found. This looks like a scan — choose "Recognize with OCR".'
                                : '(no text recognized)')
                            : text,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: text.isEmpty ? null : () => copyText(context, text),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy all text'),
                  ),
                  const SizedBox(height: 8),
                  ResultActions(
                    bytes: utf8.encode(text),
                    fileName: '$_base.txt',
                    allowOpen: false,
                    mimeType: 'text/plain',
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: text.isEmpty
                        ? null
                        : () async {
                            final b = DocxBuilder();
                            for (final (i, (page, t)) in _result!.indexed) {
                              if (i > 0) b.pageBreak();
                              if (_pageMarkers) b.heading('Page $page', 2);
                              for (final para in t.split(RegExp(r'\n\s*\n'))) {
                                if (para.trim().isNotEmpty) b.paragraph(para.trim());
                              }
                            }
                            final bytes = b.build(title: _base);
                            final ok = await FileService.saveAs(bytes, '$_base.docx', mimeType: docxMime);
                            if (ok && context.mounted) toast(context, 'Saved $_base.docx');
                          },
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Save as Word (.docx)'),
                  ),
                ],
              ],
            ),
    );
  }
}
