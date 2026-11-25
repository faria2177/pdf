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

/// How the PDF is cut.
enum _SplitMode {
  /// Every page becomes its own PDF.
  eachPage,

  /// Fixed-size chunks: 2 pages per file, 5 pages per file…
  everyN,

  /// Tap the pages you want; they become one new PDF.
  pick,

  /// Typed ranges, one PDF per range (for people who know what they want).
  ranges,
}

/// Split a PDF / extract pages, explained in plain words with a live page
/// map that shows which page ends up in which file.
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
  late _SplitMode _mode = widget.extractMode ? _SplitMode.pick : _SplitMode.eachPage;
  int _perFile = 2;
  final Set<int> _picked = {};
  final _ranges = TextEditingController();
  final _typed = TextEditingController();
  String? _problem;
  List<List<int>> _plan = const [];

  static const _groupColors = [
    Color(0xFF1E88E5),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFFFB8C00),
    Color(0xFF8E24AA),
    Color(0xFF00897B),
    Color(0xFF6D4C41),
    Color(0xFFD81B60),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    _ranges.addListener(_recompute);
  }

  @override
  void dispose() {
    _doc?.dispose();
    _ranges.dispose();
    _typed.dispose();
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
        case _SplitMode.eachPage:
          plan = [for (var i = 1; i <= _count; i++) [i]];
        case _SplitMode.everyN:
          final n = _perFile.clamp(1, _count);
          plan = [
            for (var s = 1; s <= _count; s += n) [for (var i = s; i < s + n && i <= _count; i++) i],
          ];
        case _SplitMode.pick:
          if (_picked.isEmpty) throw const FormatException('Tap the pages you want to keep');
          plan = [_picked.toList()..sort()];
        case _SplitMode.ranges:
          if (_ranges.text.trim().isEmpty) throw const FormatException('Type the page ranges, e.g. 1-3, 4-10');
          plan = parsePageGroups(_ranges.text, _count);
      }
    } on FormatException catch (e) {
      problem = e.message;
    }
    setState(() {
      _plan = plan;
      _problem = problem;
    });
  }

  void _setMode(_SplitMode m) {
    setState(() => _mode = m);
    _recompute();
  }

  /// Which output file (0-based) holds [page], or null if it is left out.
  int? _groupOf(int page) {
    for (var i = 0; i < _plan.length; i++) {
      if (_plan[i].contains(page)) return i;
    }
    return null;
  }

  void _tapPage(int page) {
    if (_mode != _SplitMode.pick) {
      // Tapping a page is the quickest way into "pick pages".
      _picked
        ..clear()
        ..add(page);
      _mode = _SplitMode.pick;
    } else if (!_picked.remove(page)) {
      _picked.add(page);
    }
    _recompute();
  }

  void _applyTyped() {
    try {
      final pages = parsePageList(_typed.text, _count);
      _picked
        ..clear()
        ..addAll(pages);
      _recompute();
      FocusScope.of(context).unfocus();
    } on FormatException catch (e) {
      toast(context, e.message);
    }
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
        final label = group.length == 1 ? 'page ${group.first}' : 'pages ${group.first}-${group.last}';
        final name = _mode == _SplitMode.pick
            ? '${_base}_pages ${formatPageList(group).replaceAll(', ', ',')}.pdf'
            : '${_base}_${(i + 1).toString().padLeft(digits, '0')} ($label).pdf';
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
    RecentFile? last;
    for (final (bytes, name) in files) {
      last = await RecentStore.instance.addBytes(bytes, name);
    }
    if (!mounted) return;

    if (how == 'share') {
      await FileService.shareBytes(files);
      return;
    }
    if (how == 'open' && last != null) {
      await openPdfInViewer(context, last.path, name: last.name);
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

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.extractMode ? 'Extract pages' : 'Split PDF')),
      bottomNavigationBar: doc == null ? null : _actions(scheme),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text("Couldn't open: $_error")))
          : doc == null
              ? const Center(child: CircularProgressIndicator())
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      sliver: SliverList.list(children: [
                        Text(
                          '${widget.name} · $_count page${_count == 1 ? '' : 's'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 14),
                        Text('How do you want to split it?', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 10),
                        _choice(
                          _SplitMode.eachPage,
                          Icons.filter_none,
                          'Every page separately',
                          'Each page becomes its own PDF — $_count files.',
                        ),
                        _choice(
                          _SplitMode.everyN,
                          Icons.view_agenda_outlined,
                          'Every few pages',
                          'Cut into equal parts, e.g. 2 pages in each file.',
                          extra: _perFileStepper(scheme),
                        ),
                        _choice(
                          _SplitMode.pick,
                          Icons.touch_app_outlined,
                          'Choose pages',
                          'Tap the pages below; they are saved as one new PDF.',
                          extra: _pickTools(),
                        ),
                        _choice(
                          _SplitMode.ranges,
                          Icons.edit_note,
                          'Custom ranges',
                          'Type page ranges; each range becomes one file.',
                          extra: _rangesField(),
                        ),
                        const SizedBox(height: 12),
                        _summary(scheme),
                        const SizedBox(height: 12),
                        Text(
                          _mode == _SplitMode.pick ? 'Tap pages to select them' : 'Pages and the file each one goes to',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                      ]),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 110,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: .72,
                        ),
                        itemCount: _count,
                        itemBuilder: (context, i) => _pageTile(doc, i + 1, scheme),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _choice(_SplitMode mode, IconData icon, String title, String subtitle, {Widget? extra}) {
    final scheme = Theme.of(context).colorScheme;
    final on = _mode == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: on ? scheme.secondaryContainer : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: on ? null : () => _setMode(mode),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: on ? scheme.primary : scheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(subtitle, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: on ? scheme.primary : scheme.outline),
                  ],
                ),
                if (on && extra != null) ...[const SizedBox(height: 10), extra],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _perFileStepper(ColorScheme scheme) {
    final max = _count < 2 ? 1 : _count;
    return Row(
      children: [
        const Text('Pages in each file'),
        const Spacer(),
        IconButton.outlined(
          onPressed: _perFile <= 1
              ? null
              : () {
                  _perFile--;
                  _recompute();
                },
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 44,
          child: Text('$_perFile', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        IconButton.outlined(
          onPressed: _perFile >= max
              ? null
              : () {
                  _perFile++;
                  _recompute();
                },
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  Widget _pickTools() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Icons.select_all, size: 18),
                label: const Text('All'),
                onPressed: () {
                  _picked.addAll([for (var i = 1; i <= _count; i++) i]);
                  _recompute();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.filter_1, size: 18),
                label: const Text('Odd'),
                onPressed: () {
                  _picked
                    ..clear()
                    ..addAll([for (var i = 1; i <= _count; i += 2) i]);
                  _recompute();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.filter_2, size: 18),
                label: const Text('Even'),
                onPressed: () {
                  _picked
                    ..clear()
                    ..addAll([for (var i = 2; i <= _count; i += 2) i]);
                  _recompute();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.clear, size: 18),
                label: const Text('Clear'),
                onPressed: () {
                  _picked.clear();
                  _recompute();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _typed,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _applyTyped(),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Or type pages: 1, 3, 5-8',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _applyTyped),
            ),
          ),
        ],
      );

  Widget _rangesField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ranges,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'e.g. 1-3, 4-10, 11-',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '“1-3, 4-10” makes two files: pages 1 to 3, and pages 4 to 10. '
            '“11-” means page 11 to the end.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      );

  Widget _summary(ColorScheme scheme) {
    if (_problem != null) {
      return Row(children: [
        Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(_problem!, style: TextStyle(color: scheme.onSurfaceVariant))),
      ]);
    }
    if (_plan.isEmpty) return const SizedBox.shrink();
    final files = _plan.length;
    final pages = _plan.fold<int>(0, (s, g) => s + g.length);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.picture_as_pdf, color: scheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              files == 1
                  ? 'You will get 1 PDF with $pages page${pages == 1 ? '' : 's'}'
                      ' (${formatPageList(_plan.first)}).'
                  : 'You will get $files PDFs'
                      '${files > 1 ? ', saved together in one ZIP' : ''}.',
              style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageTile(PdfDocument doc, int page, ColorScheme scheme) {
    final group = _groupOf(page);
    final pick = _mode == _SplitMode.pick;
    final included = group != null;
    final color = group == null ? scheme.outlineVariant : _groupColors[group % _groupColors.length];
    return GestureDetector(
      onTap: () => _tapPage(page),
      child: Column(
        children: [
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: included || _plan.isEmpty ? 1 : .4,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: included ? (pick ? scheme.primary : color) : scheme.outlineVariant, width: included ? 2.5 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PdfPageView(document: doc, pageNumber: page, maximumDpi: 36),
                    if (pick)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(
                          included ? Icons.check_circle : Icons.circle_outlined,
                          color: included ? scheme.primary : scheme.outline,
                        ),
                      )
                    else if (group != null && _plan.length > 1)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: color,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            'File ${group + 1}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('$page', style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }

  Widget _actions(ColorScheme scheme) {
    final ready = _plan.isNotEmpty && _problem == null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            IconButton.outlined(
              tooltip: 'Share',
              onPressed: ready ? () => _run('share') : null,
              icon: const Icon(Icons.share_outlined),
            ),
            const SizedBox(width: 8),
            if (_plan.length == 1) ...[
              IconButton.outlined(
                tooltip: 'Open',
                onPressed: ready ? () => _run('open') : null,
                icon: const Icon(Icons.visibility_outlined),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: FilledButton.icon(
                onPressed: ready ? () => _run('save') : null,
                icon: const Icon(Icons.save_alt),
                label: Text(
                  !ready
                      ? 'Save'
                      : _plan.length > 1
                          ? 'Save ${_plan.length} PDFs (ZIP)'
                          : 'Save PDF',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
