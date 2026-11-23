import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../services/file_service.dart';
import '../../utils/office_writers.dart';
import '../../utils/text_layout.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';
import 'tool_base.dart';

enum SheetLayout { perPage, single }

const xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

class PdfToExcelPage extends StatefulWidget {
  const PdfToExcelPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<PdfToExcelPage> createState() => _PdfToExcelPageState();
}

class _PdfToExcelPageState extends PdfToolState<PdfToExcelPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  SheetLayout _layout = SheetLayout.perPage;
  PageSelection _pages = const PageSelection.all();
  bool _header = true;
  bool _numbers = true;
  bool _skipEmpty = true;
  double _tolerance = 10;
  List<List<String>>? _preview;
  int? _previewPage;
  Uint8List? _result;
  String _stats = '';

  String get _outName => '${FileService.withoutExtension(widget.name)}.xlsx';

  Future<List<List<String>>> _tableFor(int pageNumber) async {
    final words = await pageWords(doc!.pages[pageNumber - 1]);
    var t = tableFromWords(words, columnTolerance: _tolerance);
    if (_skipEmpty) t = t.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
    return t;
  }

  List<Object?> _typed(List<String> row) => [
        for (final c in row) _numbers ? (parseNumberCell(c) ?? c) : c,
      ];

  Future<void> _showPreview() async {
    final pages = _pages.resolve(pageCount);
    final t = await _tableFor(pages.first);
    if (mounted) {
      setState(() {
        _preview = t;
        _previewPage = pages.first;
      });
    }
  }

  Future<void> _convert() async {
    final pages = _pages.resolve(pageCount);
    final out = await runWithProgress(context, 'Converting to Excel', (update) async {
      final x = XlsxBuilder();
      final combined = <List<Object?>>[];
      var rows = 0;
      var maxCols = 0;
      for (var i = 0; i < pages.length; i++) {
        update('Reading tables… page ${pages[i]}', (i + 1) / pages.length);
        final t = await _tableFor(pages[i]);
        rows += t.length;
        for (final r in t) {
          if (r.length > maxCols) maxCols = r.length;
        }
        if (_layout == SheetLayout.perPage) {
          x.addSheet('Page ${pages[i]}', [for (final (j, r) in t.indexed) j == 0 && _header ? r : _typed(r)],
              headerRow: _header);
        } else {
          for (final (j, r) in t.indexed) {
            combined.add(i == 0 && j == 0 && _header ? r : _typed(r));
          }
        }
      }
      if (_layout == SheetLayout.single) {
        x.addSheet(FileService.withoutExtension(widget.name), combined, headerRow: _header);
      }
      update('Packaging .xlsx…', null);
      return (x.build(), rows, maxCols);
    });
    if (out == null || !mounted) return;
    final (bytes, rows, cols) = out;
    setState(() {
      _result = bytes;
      _stats = '${pages.length} pages · $rows rows · up to $cols columns · ${formatBytes(bytes.length)}';
    });
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _result = null;
        _preview = null;
      });

  @override
  Widget build(BuildContext context) {
    final err = doc == null ? null : _pages.error(pageCount);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('PDF to Excel')),
      body: doc == null
          ? loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                header(),
                const SectionTitle('Workbook layout'),
                ChoiceCards<SheetLayout>(
                  value: _layout,
                  onChanged: (v) => _changed(() => _layout = v),
                  options: const [
                    (SheetLayout.perPage, Icons.tab_outlined, 'One sheet per page', 'Each PDF page gets its own worksheet'),
                    (SheetLayout.single, Icons.table_rows_outlined, 'Everything in one sheet',
                        'Rows from all pages stacked — best for long tables'),
                  ],
                ),
                const SectionTitle('Pages'),
                PageRangeSelector(pageCount: pageCount, value: _pages, onChanged: (v) => _changed(() => _pages = v)),
                const SectionTitle('Table detection'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('First row is a header'),
                  subtitle: const Text('Bold, shaded and frozen at the top'),
                  value: _header,
                  onChanged: (v) => _changed(() => _header = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Convert numbers'),
                  subtitle: const Text('1,234.50 · (45) · 12% · ৳500 become real numbers you can sum'),
                  value: _numbers,
                  onChanged: (v) => _changed(() => _numbers = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Skip empty rows'),
                  value: _skipEmpty,
                  onChanged: (v) => _changed(() => _skipEmpty = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Column matching'),
                  subtitle: Text(_tolerance < 8
                      ? 'Strict — more columns'
                      : _tolerance > 15
                          ? 'Loose — fewer, merged columns'
                          : 'Balanced'),
                ),
                Slider(
                  value: _tolerance,
                  min: 4,
                  max: 24,
                  divisions: 10,
                  label: '${_tolerance.round()} pt',
                  onChanged: (v) => _changed(() => _tolerance = v),
                ),
                OutlinedButton.icon(
                  onPressed: err == null ? _showPreview : null,
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('Preview first page'),
                ),
                if (_preview != null) ...[
                  const SizedBox(height: 8),
                  Text('Page $_previewPage · ${_preview!.length} rows', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  if (_preview!.isEmpty)
                    const Text('No text found on this page. Scanned pages need OCR first.')
                  else
                    Container(
                      decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Table(
                            defaultColumnWidth: const IntrinsicColumnWidth(),
                            border: TableBorder.all(color: scheme.outlineVariant, width: 0.5),
                            children: [
                              for (final (i, r) in _preview!.take(40).indexed)
                                TableRow(
                                  decoration: i == 0 && _header ? BoxDecoration(color: scheme.primaryContainer) : null,
                                  children: [
                                    for (final c in r)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 180),
                                          child: Text(
                                            c,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: i == 0 && _header ? FontWeight.bold : null,
                                            ),
                                            textAlign: parseNumberCell(c) != null ? TextAlign.right : TextAlign.left,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: err == null ? _convert : null,
                    icon: const Icon(Icons.table_chart_outlined),
                    label: Text(err ?? 'Convert to Excel'),
                  )
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: Text(_outName),
                    subtitle: Text(_stats),
                  ),
                  ResultActions(bytes: _result!, fileName: _outName, allowOpen: false, mimeType: xlsxMime),
                ],
              ],
            ),
    );
  }
}
