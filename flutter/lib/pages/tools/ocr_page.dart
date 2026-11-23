import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../services/file_service.dart';
import '../../services/ocr_service.dart';
import '../../utils/office_writers.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/ocr_language_picker.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';
import 'pdf_to_word_page.dart' show docxMime;
import 'tool_base.dart';

enum OcrOutput { searchablePdf, text, word }

class OcrPage extends StatefulWidget {
  const OcrPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends PdfToolState<OcrPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  List<String> _langs = const ['eng'];
  OcrModel _model = OcrModel.fast;
  OcrOutput _output = OcrOutput.searchablePdf;
  int _dpi = 300;
  PageSelection _pages = const PageSelection.all();
  bool _cancel = false;

  Uint8List? _pdf;
  List<OcrPageText>? _texts;
  Uint8List? _docx;
  List<int> _donePages = const [];

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

  Future<void> _run() async {
    final missing = await OcrService.missing(_langs, _model);
    if (!mounted) return;
    if (missing.isNotEmpty) {
      toast(context, 'Download the language data first (tap the language chip).');
      return;
    }
    await OcrService.savePrefs(_langs, _model);
    if (!mounted) return;
    final pages = _pages.resolve(pageCount);
    _cancel = false;
    List<String> images = const [];
    final ok = await runWithProgress<bool>(
      context,
      'Recognizing text',
      (update) async {
        images = await OcrService.renderPages(doc!, pages, dpi: _dpi, onProgress: (d, t) {
          update('Preparing page $d of $t', d / t * 0.25);
        });
        if (_cancel) return false;
        void progress(int d, int t) => update('Reading page $d of $t…', 0.25 + d / t * 0.75);
        if (_output == OcrOutput.searchablePdf) {
          final out = await OcrService.toSearchablePdf(
            images: images,
            languages: _langs,
            model: _model,
            dpi: _dpi,
            title: _base,
            onProgress: progress,
          );
          final f = File(out);
          _pdf = await f.readAsBytes();
          await f.delete();
        } else {
          _texts = await OcrService.toText(images: images, languages: _langs, model: _model, dpi: _dpi, onProgress: progress);
          if (_output == OcrOutput.word) {
            final b = DocxBuilder();
            for (final (i, t) in _texts!.indexed) {
              if (i > 0) b.pageBreak();
              for (final para in t.text.split(RegExp(r'\n\s*\n'))) {
                final clean = para.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
                if (clean.isNotEmpty) b.paragraph(clean);
              }
            }
            _docx = b.build(title: _base);
          }
        }
        return true;
      },
      onCancel: () async {
        _cancel = true;
        await OcrService.cancel();
      },
    );
    OcrService.cleanup(images);
    if (ok == true && mounted) setState(() => _donePages = pages);
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _pdf = null;
        _texts = null;
        _docx = null;
        _donePages = const [];
      });

  Widget _result() {
    final avg = _texts == null || _texts!.isEmpty
        ? null
        : (_texts!.map((t) => t.confidence).reduce((a, b) => a + b) / _texts!.length).round();
    switch (_output) {
      case OcrOutput.searchablePdf:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('${_base}_ocr.pdf'),
              subtitle: Text('${_donePages.length} pages · searchable · ${formatBytes(_pdf!.length)}'),
            ),
            ResultActions(bytes: _pdf!, fileName: '${_base}_ocr.pdf'),
          ],
        );
      case OcrOutput.text:
      case OcrOutput.word:
        final text = [
          for (final (i, t) in _texts!.indexed) '--- Page ${_donePages[i]} ---\n${t.text.trim()}',
        ].join('\n\n');
        final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !w.startsWith('---')).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$words words · average confidence ${avg ?? 0}%', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(child: SelectableText(text.isEmpty ? '(no text recognized)' : text)),
            ),
            const SizedBox(height: 10),
            if (_output == OcrOutput.word)
              ResultActions(bytes: _docx!, fileName: '${_base}_ocr.docx', allowOpen: false, mimeType: docxMime)
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => copyText(context, text),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy all text'),
                  ),
                  const SizedBox(height: 8),
                  ResultActions(
                    bytes: utf8.encode(text),
                    fileName: '${_base}_ocr.txt',
                    allowOpen: false,
                    mimeType: 'text/plain',
                  ),
                ],
              ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = doc == null ? null : _pages.error(pageCount);
    final done = _pdf != null || _texts != null;
    return Scaffold(
      appBar: AppBar(title: const Text('OCR PDF')),
      body: doc == null
          ? loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                header(),
                const SectionTitle('Document language'),
                OcrLanguagePicker(
                  selected: _langs,
                  model: _model,
                  onChanged: (v) => _changed(() => _langs = v),
                  onModelChanged: (m) => _changed(() => _model = m),
                ),
                const SectionTitle('Output'),
                ChoiceCards<OcrOutput>(
                  value: _output,
                  onChanged: (v) => _changed(() => _output = v),
                  options: const [
                    (OcrOutput.searchablePdf, Icons.picture_as_pdf_outlined, 'Searchable PDF',
                        'Looks the same, but text can be searched, selected and copied'),
                    (OcrOutput.text, Icons.notes, 'Plain text', 'Recognized text to copy or save as .txt'),
                    (OcrOutput.word, Icons.description_outlined, 'Word document', 'Recognized text as an editable .docx'),
                  ],
                ),
                const SectionTitle('Scan quality'),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 200, label: Text('Fast\n200 dpi', textAlign: TextAlign.center)),
                    ButtonSegment(value: 300, label: Text('Accurate\n300 dpi', textAlign: TextAlign.center)),
                    ButtonSegment(value: 400, label: Text('Small text\n400 dpi', textAlign: TextAlign.center)),
                  ],
                  selected: {_dpi},
                  onSelectionChanged: (s) => _changed(() => _dpi = s.first),
                ),
                const SectionTitle('Pages'),
                PageRangeSelector(pageCount: pageCount, value: _pages, onChanged: (v) => _changed(() => _pages = v)),
                const SizedBox(height: 16),
                if (!done)
                  FilledButton.icon(
                    onPressed: err == null && _langs.isNotEmpty ? _run : null,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: Text(err ?? (_langs.isEmpty ? 'Choose a language' : 'Start OCR')),
                  )
                else
                  _result(),
              ],
            ),
    );
  }
}
