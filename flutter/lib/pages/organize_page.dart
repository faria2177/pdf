import 'dart:io';
import 'dart:typed_data';

import 'package:animated_reorderable_list/animated_reorderable_list.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../utils/image_tools.dart';
import '../widgets/dialogs.dart';
import 'home_page.dart';

/// One loaded source (a PDF file, an image turned into a 1-page PDF, or a blank page).
class _Source {
  _Source(this.id, this.name, this.doc, {this.path});
  final int id;
  final String name;
  final PdfDocument doc;

  /// Set for real PDF files; lets a single-source save keep the original's metadata/bookmarks.
  final String? path;
}

/// One page tile. Immutable so undo/redo can keep snapshots of the list.
class _PageItem {
  _PageItem({required this.uid, required this.source, required this.pageIndex, required this.rotation});

  final int uid;
  final _Source source;
  final int pageIndex; // 0-based in source.doc
  final PdfPageRotation rotation; // absolute target rotation

  PdfPage get page => source.doc.pages[pageIndex];

  _PageItem copyWith({int? uid, PdfPageRotation? rotation}) =>
      _PageItem(uid: uid ?? this.uid, source: source, pageIndex: pageIndex, rotation: rotation ?? this.rotation);

  PdfPage proxyFor(PdfPage base) => base.rotation == rotation ? base : base.rotatedTo(rotation);
}

/// Page grid: the PdfCraft "Organize pages" / "Combine files" / images-to-PDF screen.
/// Tap pages to select; long-press and drag to move.
class OrganizePage extends StatefulWidget {
  const OrganizePage({required this.sources, required this.title, required this.outputName, super.key});

  final List<PickedFile> sources;
  final String title;
  final String outputName;

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  final _sources = <_Source>[];
  var _pages = <_PageItem>[];
  final _selected = <int>{};
  final _undo = <List<_PageItem>>[];
  final _redo = <List<_PageItem>>[];
  int _nextUid = 0;
  int _nextSourceId = 0;
  bool _loading = true;
  bool _savedSinceEdit = false;
  bool _thumbLarge = false;

  bool get _dirty => _undo.isNotEmpty && !_savedSinceEdit || (_sources.length > 1 && !_savedSinceEdit);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInitial());
  }

  @override
  void dispose() {
    for (final s in _sources) {
      s.doc.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final items = await _loadFiles(widget.sources);
    if (!mounted) return;
    setState(() {
      _pages = items;
      _loading = false;
    });
    if (items.isEmpty) {
      toast(context, 'Nothing could be opened.');
      Navigator.of(context).maybePop();
    }
  }

  Future<List<_PageItem>> _loadFiles(List<PickedFile> files) async {
    final result = <_PageItem>[];
    for (final f in files) {
      try {
        final _Source src;
        if (f.isPdf) {
          final doc = await openPdfDocument(context, f.path);
          src = _Source(_nextSourceId++, f.name, doc, path: f.path);
        } else {
          final bytes = await File(f.path).readAsBytes();
          final doc = await imageToPdfDocument(bytes, f.name);
          src = _Source(_nextSourceId++, f.name, doc);
        }
        _sources.add(src);
        for (var i = 0; i < src.doc.pages.length; i++) {
          result.add(_PageItem(uid: _nextUid++, source: src, pageIndex: i, rotation: src.doc.pages[i].rotation));
        }
      } catch (e) {
        if (mounted) toast(context, '${f.name}: $e');
      }
    }
    return result;
  }

  // ------------------------------------------------------------------ editing

  void _commit(List<_PageItem> next) {
    setState(() {
      _undo.add(_pages);
      if (_undo.length > 100) _undo.removeAt(0);
      _redo.clear();
      _pages = next;
      _savedSinceEdit = false;
      final alive = next.map((e) => e.uid).toSet();
      _selected.retainAll(alive);
    });
  }

  void _doUndo() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_pages);
      _pages = _undo.removeLast();
      _selected.retainAll(_pages.map((e) => e.uid));
    });
  }

  void _doRedo() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_pages);
      _pages = _redo.removeLast();
      _selected.retainAll(_pages.map((e) => e.uid));
    });
  }

  bool _needSelection() {
    if (_selected.isNotEmpty) return true;
    toast(context, 'Tap pages to select them first');
    return false;
  }

  void _rotate({required bool clockwise, bool all = false}) {
    if (!all && !_needSelection()) return;
    _commit([
      for (final p in _pages)
        if (all || _selected.contains(p.uid))
          p.copyWith(rotation: clockwise ? p.rotation.rotateCW90 : p.rotation.rotateCCW90)
        else
          p,
    ]);
  }

  Future<void> _delete() async {
    if (!_needSelection()) return;
    if (_selected.length == _pages.length) {
      toast(context, "Can't delete every page");
      return;
    }
    _commit(_pages.where((p) => !_selected.contains(p.uid)).toList());
    setState(_selected.clear);
  }

  void _duplicate() {
    if (!_needSelection()) return;
    final next = <_PageItem>[];
    for (final p in _pages) {
      next.add(p);
      if (_selected.contains(p.uid)) next.add(p.copyWith(uid: _nextUid++));
    }
    _commit(next);
  }

  /// Moves the selected pages one step earlier (-1) or later (+1), keeping their order.
  void _move(int dir) {
    if (!_needSelection()) return;
    final list = [..._pages];
    if (dir < 0) {
      for (var i = 1; i < list.length; i++) {
        if (_selected.contains(list[i].uid) && !_selected.contains(list[i - 1].uid)) {
          final t = list[i - 1];
          list[i - 1] = list[i];
          list[i] = t;
        }
      }
    } else {
      for (var i = list.length - 2; i >= 0; i--) {
        if (_selected.contains(list[i].uid) && !_selected.contains(list[i + 1].uid)) {
          final t = list[i + 1];
          list[i + 1] = list[i];
          list[i] = t;
        }
      }
    }
    _commit(list);
  }

  void _moveTo({required bool start}) {
    if (!_needSelection()) return;
    final sel = _pages.where((p) => _selected.contains(p.uid)).toList();
    final rest = _pages.where((p) => !_selected.contains(p.uid)).toList();
    _commit(start ? [...sel, ...rest] : [...rest, ...sel]);
  }

  void _reverse() => _commit(_pages.reversed.toList());

  /// Index after the last selected page, or the end.
  int get _insertIndex {
    for (var i = _pages.length - 1; i >= 0; i--) {
      if (_selected.contains(_pages[i].uid)) return i + 1;
    }
    return _pages.length;
  }

  Future<void> _insertBlank() async {
    final at = _insertIndex;
    final ref = at > 0 ? _pages[at - 1].page : (_pages.isNotEmpty ? _pages.first.page : null);
    final doc = await blankPageDocument(width: ref?.width ?? a4Width, height: ref?.height ?? a4Height);
    final src = _Source(_nextSourceId++, 'Blank page', doc);
    _sources.add(src);
    final item = _PageItem(uid: _nextUid++, source: src, pageIndex: 0, rotation: doc.pages.first.rotation);
    _commit([..._pages.sublist(0, at), item, ..._pages.sublist(at)]);
  }

  Future<void> _insertFromFile() async {
    final files = await FileService.pickPdfsOrImages();
    if (files.isEmpty || !mounted) return;
    final at = _insertIndex;
    setState(() => _loading = true);
    final items = await _loadFiles(files);
    if (!mounted) return;
    setState(() => _loading = false);
    if (items.isEmpty) return;
    _commit([..._pages.sublist(0, at), ...items, ..._pages.sublist(at)]);
  }

  void _toggle(_PageItem p) {
    setState(() {
      if (!_selected.remove(p.uid)) _selected.add(p.uid);
    });
  }

  void _selectAll() => setState(() {
        if (_selected.length == _pages.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(_pages.map((e) => e.uid));
        }
      });

  void _preview(_PageItem p, int position) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Page $position · ${p.source.name} p.${p.pageIndex + 1}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                maxScale: 5,
                child: AspectRatio(
                  aspectRatio: _aspect(p),
                  child: PdfPageView(
                    document: p.source.doc,
                    pageNumber: p.pageIndex + 1,
                    rotationOverride: p.rotation,
                    maximumDpi: 200,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  double _aspect(_PageItem p) {
    final page = p.page;
    // Page width/height already include the page's own rotation; adjust for our extra rotation.
    final extra = (p.rotation.index - page.rotation.index) % 2 != 0;
    final w = extra ? page.height : page.width;
    final h = extra ? page.width : page.height;
    return h == 0 ? 0.7 : w / h;
  }

  // ------------------------------------------------------------------ output

  Future<Uint8List> _encode() async {
    final singleSource = _sources.where((s) => _pages.any((p) => p.source == s)).toList();
    final src = singleSource.length == 1 ? singleSource.first : null;
    if (src?.path != null) {
      // Same file only: reopen it and rearrange its pages so metadata, bookmarks and forms survive.
      final path = src!.path!;
      final dest = await PdfDocument.openFile(path, passwordProvider: () => knownPassword(path));
      try {
        final base = [...dest.pages];
        dest.pages = [for (final p in _pages) p.proxyFor(base[p.pageIndex])];
        return await dest.encodePdf();
      } finally {
        await dest.dispose();
      }
    }
    final out = await PdfDocument.createNew(sourceName: widget.outputName);
    try {
      out.pages = [for (final p in _pages) p.proxyFor(p.page)];
      return await out.encodePdf();
    } finally {
      await out.dispose();
    }
  }

  String get _outName {
    final base = FileService.withoutExtension(widget.outputName);
    return widget.sources.length == 1 && widget.sources.first.isPdf ? '${base}_edited.pdf' : '$base.pdf';
  }

  Future<void> _output(String how) async {
    final bytes = await withProgress(context, 'Building PDF…', _encode);
    if (bytes == null || !mounted) return;
    switch (how) {
      case 'save':
        final ok = await FileService.saveAs(bytes, _outName);
        if (ok) {
          _savedSinceEdit = true;
          if (mounted) toast(context, 'Saved $_outName');
        }
      case 'share':
        await FileService.shareBytes([(bytes, _outName)]);
      case 'open':
        final path = await FileService.storeInLibrary(bytes, _outName);
        _savedSinceEdit = true;
        if (mounted) await openPdfInViewer(context, path, name: _outName);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final multiSource = _sources.length > 1;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirm(context, 'Your changes have not been saved.', ok: 'Discard', title: 'Leave?');
        if (leave && context.mounted) {
          _savedSinceEdit = true;
          _undo.clear();
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selected.isEmpty ? widget.title : '${_selected.length} selected'),
          actions: [
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo.isEmpty ? null : _doUndo),
            IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: _redo.isEmpty ? null : _doRedo),
            IconButton(
              tooltip: _selected.length == _pages.length ? 'Select none' : 'Select all',
              icon: Icon(_selected.length == _pages.length && _pages.isNotEmpty ? Icons.deselect : Icons.select_all),
              onPressed: _pages.isEmpty ? null : _selectAll,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'start':
                    _moveTo(start: true);
                  case 'end':
                    _moveTo(start: false);
                  case 'dup':
                    _duplicate();
                  case 'reverse':
                    _reverse();
                  case 'rotall':
                    _rotate(clockwise: true, all: true);
                  case 'size':
                    setState(() => _thumbLarge = !_thumbLarge);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'start', child: Text('Move selection to start')),
                PopupMenuItem(value: 'end', child: Text('Move selection to end')),
                PopupMenuItem(value: 'dup', child: Text('Duplicate selection')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'reverse', child: Text('Reverse page order')),
                PopupMenuItem(value: 'rotall', child: Text('Rotate all pages right')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'size', child: Text('Larger / smaller thumbnails')),
              ],
            ),
          ],
        ),
        body: _loading && _pages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_loading) const LinearProgressIndicator(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '${_pages.length} pages · tap to select · long-press and drag to move',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final target = _thumbLarge ? 200.0 : 120.0;
                        final cols = (c.maxWidth / target).floor().clamp(2, 10);
                        return AnimatedReorderableGridView<_PageItem>(
                          items: _pages,
                          isSameItem: (a, b) => a.uid == b.uid,
                          padding: const EdgeInsets.all(8),
                          sliverGridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            childAspectRatio: 0.66,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                          dragStartDelay: const Duration(milliseconds: 250),
                          insertDuration: const Duration(milliseconds: 150),
                          removeDuration: const Duration(milliseconds: 200),
                          onReorder: (oldIndex, newIndex) {
                            final list = [..._pages];
                            final item = list.removeAt(oldIndex);
                            list.insert(newIndex.clamp(0, list.length), item);
                            _commit(list);
                          },
                          itemBuilder: (context, index) {
                            final p = _pages[index];
                            final sel = _selected.contains(p.uid);
                            return _Thumb(
                              key: ValueKey(p.uid),
                              item: p,
                              position: index + 1,
                              selected: sel,
                              caption: multiSource ? p.source.name : null,
                              onTap: () => _toggle(p),
                              onPreview: () => _preview(p, index + 1),
                              scheme: scheme,
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: _pages.isEmpty
            ? null
            : SafeArea(
                child: Material(
                  elevation: 6,
                  color: scheme.surfaceContainer,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            _Tool(Icons.rotate_left, 'Left', () => _rotate(clockwise: false)),
                            _Tool(Icons.rotate_right, 'Right', () => _rotate(clockwise: true)),
                            _Tool(Icons.delete_outline, 'Delete', _delete),
                            _Tool(Icons.arrow_back, 'Earlier', () => _move(-1)),
                            _Tool(Icons.arrow_forward, 'Later', () => _move(1)),
                            _Tool(Icons.note_add_outlined, 'Blank', _insertBlank),
                            _Tool(Icons.library_add_outlined, 'Insert file', _insertFromFile),
                            _Tool(Icons.copy_all_outlined, 'Duplicate', _duplicate),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _output('share'),
                                icon: const Icon(Icons.share),
                                label: const Text('Share'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _output('open'),
                                icon: const Icon(Icons.visibility_outlined),
                                label: const Text('Open'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => _output('save'),
                                icon: const Icon(Icons.save_alt),
                                label: const Text('Save'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.item,
    required this.position,
    required this.selected,
    required this.onTap,
    required this.onPreview,
    required this.scheme,
    this.caption,
    super.key,
  });

  final _PageItem item;
  final int position;
  final bool selected;
  final String? caption;
  final VoidCallback onTap;
  final VoidCallback onPreview;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: selected ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 3),
      ),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 22),
              child: PdfPageView(
                document: item.source.doc,
                pageNumber: item.pageIndex + 1,
                rotationOverride: item.rotation,
                maximumDpi: 50,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                color: selected ? scheme.primary : scheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    Text(
                      '$position',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: selected ? scheme.onPrimary : scheme.onSurface,
                      ),
                    ),
                    if (caption != null) ...[
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (selected)
              Positioned(
                top: 6,
                left: 6,
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primary,
                  child: Icon(Icons.check, size: 14, color: scheme.onPrimary),
                ),
              ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
                iconSize: 16,
                tooltip: 'Preview',
                icon: const Icon(Icons.zoom_in),
                onPressed: onPreview,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
