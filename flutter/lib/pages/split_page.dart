import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../services/recent_store.dart';
import '../utils/page_ranges.dart';
import '../widgets/dialogs.dart';
import 'home_page.dart';

enum _SplitMode { everyN, ranges, extract }

/// PdfCraft's "Split document" and "Extract pages".
class SplitPage extends StatefulWidget {
  const SplitPage({required this.path, required this.name, required this.extractMode, super.key});

  final String path;
  final String name;
  final bool extractMode;

  @override
  State<SplitPage> createState() => _SplitPageState();
}

class _SplitPageState extends State<SplitPage> {
  PdfDocument? _doc;
  Object? _error;
  late _SplitMode _mode = widget.extractMode ? _SplitMode.extract : _SplitMode.everyN;
  final _n = TextEditingController(text: '1');
  final _ranges = TextEditingController();
  final _extract = TextEditingController();
  String? _problem;
  List<List<int>> _plan = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    for (final c in [_n, _ranges, _extract]) {
      c.addListener(_recompute);
    }
  }

  @override
  void dispose() {
    _doc?.dispose();
    _n.dispose();
    _ranges.dispose();
    _extract.dispose();
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
      _recompute();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int get _count => _doc?.pages.length ?? 0;

  void _recompute() {
    if (_doc == null) return;
    List<List<int>> plan = const [];
    String? problem;
    try {
      switch (_mode) {
        case _SplitMode.everyN:
          final n = int.tryParse(_n.text.trim());
          if (n == null || n < 1) throw const FormatException('Enter a number of pages (1 or more)');
          plan = [
            for (var s = 1; s <= _count; s += n) [for (var i = s; i < s + n && i <= _count; i++) i],
          ];
        case _SplitMode.ranges:
          plan = parsePageGroups(_ranges.text, _count);
        case _SplitMode.extract:
          plan = [parsePageList(_extract.text, _count)];
      }
    } on FormatException catch (e) {
      problem = e.message;
    }
    setState(() {
      _plan = plan;
      _problem = problem;
    });
  }

  String get _base => FileService.withoutExtension(widget.name);

  Future<List<(Uint8List, String)>> _build() async {
    final doc = _doc!;
    final out = <(Uint8List, String)>[];
    final digits = _plan.length.toString().length;
    for (var i = 0; i < _plan.length; i++) {
      final group = _plan[i];
      final part = await PdfDocument.createNew(sourceName: 'part$i.pdf');
      try {
        part.pages = [for (final n in group) doc.pages[n - 1]];
        final bytes = await part.encodePdf();
        final label = group.length == 1 ? 'p${group.first}' : 'p${group.first}-${group.last}';
        final name = _mode == _SplitMode.extract
            ? '${_base}_pages_${formatPageList(group).replaceAll(', ', '_').replaceAll(' ', '')}.pdf'
            : '${_base}_${(i + 1).toString().padLeft(digits, '0')}_$label.pdf';
        out.add((bytes, name));
      } finally {
        await part.dispose();
      }
    }
    return out;
  }

  Future<void> _run(String how) async {
    if (_plan.isEmpty || _problem != null) return;
    final files = await withProgress(context, 'Creating ${_plan.length} file(s)…', _build);
    if (files == null || files.isEmpty || !mounted) return;
    for (final (bytes, name) in files) {
      await RecentStore.instance.addBytes(bytes, name);
    }
    if (!mounted) return;

    if (how == 'share') {
      await FileService.shareBytes(files);
      return;
    }
    if (how == 'open' && files.length == 1) {
      final r = await RecentStore.instance.addBytes(files.first.$1, files.first.$2);
      if (mounted) await openPdfInViewer(context, r.path, name: r.name);
      return;
    }
    if (files.length == 1) {
      final ok = await FileService.saveAs(files.first.$1, files.first.$2);
      if (ok && mounted) toast(context, 'Saved ${files.first.$2}');
      return;
    }
    // Several parts: one ZIP through a single "Save as" dialog.
    final archive = Archive();
    for (final (bytes, name) in files) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final zip = ZipEncoder().encodeBytes(archive);
    final zipName = '${_base}_split.zip';
    final ok = await FileService.saveAs(zip, zipName, mimeType: 'application/zip');
    if (ok && mounted) toast(context, 'Saved $zipName (${files.length} PDFs)');
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(title: Text(widget.extractMode ? 'Extract pages' : 'Split PDF')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text("Couldn't open: $_error")))
          : doc == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: SizedBox(
                        width: 48,
                        child: PdfPageView(document: doc, pageNumber: 1, maximumDpi: 40),
                      ),
                      title: Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$_count pages'),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<_SplitMode>(
                      segments: const [
                        ButtonSegment(value: _SplitMode.everyN, label: Text('Every N'), icon: Icon(Icons.splitscreen)),
                        ButtonSegment(value: _SplitMode.ranges, label: Text('Ranges'), icon: Icon(Icons.call_split)),
                        ButtonSegment(value: _SplitMode.extract, label: Text('Extract'), icon: Icon(Icons.content_cut)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) {
                        setState(() => _mode = s.first);
                        _recompute();
                      },
                    ),
                    const SizedBox(height: 20),
                    switch (_mode) {
                      _SplitMode.everyN => TextField(
                          controller: _n,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Pages per file',
                            helperText: '1 = one page per file',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      _SplitMode.ranges => TextField(
                          controller: _ranges,
                          decoration: const InputDecoration(
                            labelText: 'Ranges, one file each',
                            hintText: 'e.g. 1-3, 4-10, 11-',
                            helperText: 'Each comma-separated part becomes its own PDF',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      _SplitMode.extract => TextField(
                          controller: _extract,
                          decoration: const InputDecoration(
                            labelText: 'Pages to copy into a new PDF',
                            hintText: 'e.g. 1, 3, 5-8',
                            helperText: 'Pages keep the order you type',
                            border: OutlineInputBorder(),
                          ),
                        ),
                    },
                    const SizedBox(height: 16),
                    if (_problem != null && (_mode == _SplitMode.everyN || _textFor(_mode).isNotEmpty))
                      Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                    else if (_plan.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _plan.length == 1
                                    ? 'Creates 1 file with ${_plan.first.length} pages'
                                    : 'Creates ${_plan.length} files from $_count pages',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              for (final (i, g) in _plan.take(8).indexed)
                                Text('${i + 1}. pages ${formatPageList(g)}', style: Theme.of(context).textTheme.bodySmall),
                              if (_plan.length > 8)
                                Text('… and ${_plan.length - 8} more', style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _plan.isEmpty || _problem != null ? null : () => _run('share'),
                            icon: const Icon(Icons.share),
                            label: const Text('Share'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_plan.length == 1) ...[
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _problem != null ? null : () => _run('open'),
                              icon: const Icon(Icons.visibility_outlined),
                              label: const Text('Open'),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _plan.isEmpty || _problem != null ? null : () => _run('save'),
                            icon: const Icon(Icons.save_alt),
                            label: Text(_plan.length > 1 ? 'Save ZIP' : 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }

  String _textFor(_SplitMode m) => switch (m) {
        _SplitMode.everyN => _n.text,
        _SplitMode.ranges => _ranges.text.trim(),
        _SplitMode.extract => _extract.text.trim(),
      };
}
