import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../services/recent_store.dart';
import '../utils/image_tools.dart';
import '../widgets/dialogs.dart';
import 'organize_page.dart';
import 'split_page.dart';

enum ViewLayout {
  continuous('Continuous scroll', Icons.view_agenda_outlined),
  single('One page at a time', Icons.crop_portrait),
  horizontal('Horizontal scroll', Icons.view_week_outlined),
  twoUp('Two-up (book)', Icons.menu_book_outlined);

  const ViewLayout(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _invertColors = ColorFilter.matrix([
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

class ViewerPage extends StatefulWidget {
  const ViewerPage({required this.path, required this.name, super.key});

  final String path;
  final String name;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _controller = PdfViewerController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  late PdfDocumentRef _docRef = _makeRef();
  PdfDocument? _document;
  PdfTextSearcher? _searcher;
  List<PdfOutlineNode>? _outline;
  int _page = 1;
  bool _searching = false;
  bool _darkPages = false;
  bool _coverPage = true;
  ViewLayout _layout = ViewLayout.continuous;

  PdfDocumentRef _makeRef() =>
      PdfDocumentRefFile(widget.path, passwordProvider: passwordProviderFor(context, widget.path));

  @override
  void dispose() {
    _searcher?.removeListener(_update);
    _searcher?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  int get _pageCount => _document?.pages.length ?? 0;

  PdfPageLayoutStrategy get _strategy => switch (_layout) {
        ViewLayout.continuous => const SequentialPagesLayout(),
        ViewLayout.single => const SequentialPagesLayout(fitMode: PdfFitMode.fit),
        ViewLayout.horizontal => const SequentialPagesLayout(scrollDirection: Axis.horizontal, fitMode: PdfFitMode.fit),
        ViewLayout.twoUp => FacingPagesLayout(coverPage: _coverPage, fitMode: PdfFitMode.fit),
      };

  // ------------------------------------------------------------------ actions

  void _startSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _stopSearch() {
    _searcher?.resetTextSearch();
    _searchController.clear();
    setState(() => _searching = false);
  }

  void _runSearch(String text) {
    final s = _searcher;
    if (s == null) return;
    if (text.trim().isEmpty) {
      s.resetTextSearch();
    } else {
      s.startTextSearch(text.trim(), caseInsensitive: true, goToFirstMatch: true);
    }
  }

  Future<void> _goToPageDialog() async {
    if (_pageCount == 0) return;
    final v = await askText(
      context,
      title: 'Go to page',
      hint: '1 – $_pageCount',
      keyboardType: TextInputType.number,
      okLabel: 'Go',
    );
    final n = int.tryParse(v?.trim() ?? '');
    if (n == null) return;
    if (n < 1 || n > _pageCount) {
      if (mounted) toast(context, 'Page must be between 1 and $_pageCount');
      return;
    }
    await _controller.goToPage(pageNumber: n);
  }

  void _showOutline() {
    final items = <({PdfOutlineNode node, int level})>[];
    void walk(List<PdfOutlineNode> nodes, int level) {
      for (final n in nodes) {
        items.add((node: n, level: level));
        walk(n.children, level + 1);
      }
    }

    walk(_outline ?? const [], 0);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => items.isEmpty
            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('This document has no bookmarks.')))
            : ListView.builder(
                controller: scroll,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final it = items[i];
                  final pageNo = it.node.dest?.pageNumber;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.only(left: 16.0 + it.level * 18, right: 16),
                    title: Text(it.node.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: pageNo == null ? null : Text('$pageNo'),
                    onTap: () {
                      Navigator.pop(context);
                      _controller.goToDest(it.node.dest);
                    },
                  );
                },
              ),
      ),
    );
  }

  void _showThumbnails() {
    final doc = _document;
    if (doc == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => GridView.builder(
          controller: scroll,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            childAspectRatio: 0.68,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: doc.pages.length,
          itemBuilder: (context, i) {
            final current = i + 1 == _page;
            return InkWell(
              onTap: () {
                Navigator.pop(context);
                _controller.goToPage(pageNumber: i + 1, anchor: PdfPageAnchor.top);
              },
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: current ? Theme.of(context).colorScheme.primary : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: PdfPageView(document: doc, pageNumber: i + 1, maximumDpi: 60),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${i + 1}', style: TextStyle(fontWeight: current ? FontWeight.bold : null)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _exportPageImage() async {
    final doc = _document;
    if (doc == null) return;
    final page = doc.pages[_page - 1];
    final png = await withProgress(context, 'Rendering page $_page…', () => renderPageToPng(page, dpi: 200));
    if (png == null || !mounted) return;
    final name = '${FileService.withoutExtension(widget.name)}_p$_page.png';
    await RecentStore.instance.addBytes(png, name);
    if (!mounted) return;
    final ok = await FileService.saveAs(png, name, mimeType: 'image/png');
    if (ok && mounted) toast(context, 'Saved $name');
  }

  Future<void> _copyPageText() async {
    final doc = _document;
    if (doc == null) return;
    final text = await doc.pages[_page - 1].loadText();
    if (!mounted) return;
    final full = text?.fullText.trim() ?? '';
    if (full.isEmpty) {
      toast(context, 'No text on this page (it may be a scan).');
      return;
    }
    await copyText(context, full);
  }

  Future<void> _saveCopy({bool removePassword = false}) async {
    final doc = _document;
    if (doc == null) return;
    final bytes = removePassword
        ? await withProgress(context, 'Removing password…', () => doc.encodePdf(removeSecurity: true))
        : await File(widget.path).readAsBytes();
    if (bytes == null || !mounted) return;
    final name = removePassword ? '${FileService.withoutExtension(widget.name)}_unlocked.pdf' : widget.name;
    if (removePassword) await RecentStore.instance.addBytes(bytes, name);
    if (!mounted) return;
    final ok = await FileService.saveAs(bytes, name);
    if (ok && mounted) toast(context, 'Saved $name');
  }

  Future<void> _share() async {
    final bytes = await File(widget.path).readAsBytes();
    await FileService.shareBytes([(bytes, widget.name)]);
  }

  void _showInfo() {
    final doc = _document;
    if (doc == null) return;
    final size = File(widget.path).lengthSync();
    final first = doc.pages.isEmpty ? null : doc.pages.first;
    String mm(double pt) => (pt * 25.4 / 72).toStringAsFixed(0);
    final perms = doc.permissions;
    final rows = <(String, String)>[
      ('File', widget.name),
      ('Size', _formatBytes(size)),
      ('Pages', '${doc.pages.length}'),
      if (first != null) ('Page size', '${mm(first.width)} × ${mm(first.height)} mm'),
      ('Bookmarks', (_outline?.isNotEmpty ?? false) ? 'Yes' : 'None'),
      ('Encrypted', doc.isEncrypted ? 'Yes' : 'No'),
      if (perms != null) ...[
        ('Copying', perms.allowsCopying ? 'Allowed' : 'Not allowed'),
        ('Printing', perms.allowsPrinting ? 'Allowed' : 'Not allowed'),
        ('Assembly', perms.allowsDocumentAssembly ? 'Allowed' : 'Not allowed'),
        ('Annotations', perms.allowsModifyAnnotations ? 'Allowed' : 'Not allowed'),
      ],
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Document properties'),
        content: SingleChildScrollView(
          child: Table(
            columnWidths: const {0: IntrinsicColumnWidth()},
            children: [
              for (final (k, v) in rows)
                TableRow(children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 16, bottom: 8),
                    child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(v)),
                ]),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _openOrganizer() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrganizePage(
        sources: [PickedFile(widget.path, widget.name)],
        title: 'Organize pages',
        outputName: widget.name,
      ),
    ));
  }

  Future<void> _openSplit() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SplitPage(path: widget.path, name: widget.name, extractMode: false),
    ));
  }

  Future<void> _handleLink(PdfLink link) async {
    final url = link.url;
    if (url != null) {
      final go = await confirm(context, url.toString(), title: 'Open link?', ok: 'Open');
      if (go) await launchUrl(url, mode: LaunchMode.externalApplication);
    } else if (link.dest != null) {
      await _controller.goToDest(link.dest);
    }
  }

  // ------------------------------------------------------------------ build

  PreferredSizeWidget _buildAppBar() {
    if (_searching) {
      final s = _searcher;
      final count = s?.matches.length ?? 0;
      final idx = s?.currentIndex;
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _stopSearch),
        title: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'Search in document', border: InputBorder.none),
          onSubmitted: _runSearch,
        ),
        bottom: (s?.isSearching ?? false)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: s!.searchProgress, minHeight: 3),
              )
            : null,
        actions: [
          if (s != null && (s.hasMatches || _searchController.text.isNotEmpty))
            Center(child: Text(count == 0 ? '0' : '${(idx ?? 0) + 1}/$count')),
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: count == 0 ? null : () => s!.goToPrevMatch(),
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: count == 0 ? null : () => s!.goToNextMatch(),
          ),
        ],
      );
    }

    final ready = _document != null;
    return AppBar(
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          if (ready) Text('Page $_page of $_pageCount', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: ready ? _startSearch : null),
        MenuAnchor(
          menuChildren: [
            for (final l in ViewLayout.values)
              RadioMenuButton<ViewLayout>(
                value: l,
                groupValue: _layout,
                onChanged: (v) => setState(() => _layout = v!),
                child: Text(l.label),
              ),
            CheckboxMenuButton(
              value: _coverPage,
              onChanged: _layout == ViewLayout.twoUp ? (v) => setState(() => _coverPage = v!) : null,
              child: const Text('Cover page alone'),
            ),
            const Divider(height: 1),
            CheckboxMenuButton(
              value: _darkPages,
              onChanged: (v) => setState(() => _darkPages = v!),
              child: const Text('Dark pages'),
            ),
          ],
          builder: (context, menu, _) => IconButton(
            tooltip: 'View',
            icon: Icon(_layout.icon),
            onPressed: ready ? () => menu.isOpen ? menu.close() : menu.open() : null,
          ),
        ),
        PopupMenuButton<String>(
          enabled: ready,
          onSelected: (v) {
            switch (v) {
              case 'goto':
                _goToPageDialog();
              case 'outline':
                _showOutline();
              case 'thumbs':
                _showThumbnails();
              case 'organize':
                _openOrganizer();
              case 'split':
                _openSplit();
              case 'image':
                _exportPageImage();
              case 'text':
                _copyPageText();
              case 'save':
                _saveCopy();
              case 'unlock':
                _saveCopy(removePassword: true);
              case 'share':
                _share();
              case 'info':
                _showInfo();
            }
          },
          itemBuilder: (context) => [
            _item('goto', Icons.numbers, 'Go to page…'),
            _item('outline', Icons.bookmarks_outlined, 'Bookmarks'),
            _item('thumbs', Icons.grid_view, 'Page thumbnails'),
            const PopupMenuDivider(),
            _item('organize', Icons.dashboard_customize_outlined, 'Organize pages'),
            _item('split', Icons.call_split, 'Split / extract'),
            _item('image', Icons.image_outlined, 'Save page as image'),
            _item('text', Icons.copy, 'Copy page text'),
            const PopupMenuDivider(),
            _item('save', Icons.save_alt, 'Save a copy…'),
            if (_document?.isEncrypted ?? false) _item('unlock', Icons.lock_open, 'Save without password…'),
            _item('share', Icons.share, 'Share'),
            _item('info', Icons.info_outline, 'Properties'),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label) => PopupMenuItem(
        value: value,
        child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
      );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark || _darkPages;
    final horizontal = _layout == ViewLayout.horizontal;
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searching) _stopSearch();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: PdfViewer(
          _docRef,
          controller: _controller,
          params: PdfViewerParams(
            layoutStrategy: _strategy,
            paging: _layout == ViewLayout.single ? const PdfPaging() : null,
            pageAnchor: horizontal ? PdfPageAnchor.left : PdfPageAnchor.top,
            pageAnchorEnd: horizontal ? PdfPageAnchor.right : PdfPageAnchor.bottom,
            backgroundColor: dark ? const Color(0xFF202124) : const Color(0xFFE6E6E8),
            pageImageColorFilter: _darkPages ? _invertColors : null,
            textSelectionParams: const PdfTextSelectionParams(),
            linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _handleLink),
            pagePaintCallbacks: [if (_searcher != null) _searcher!.pageTextMatchPaintCallback],
            loadingBannerBuilder: (context, downloaded, total) => const Center(child: CircularProgressIndicator()),
            errorBannerBuilder: (context, error, stack, ref) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text("Couldn't open this PDF.\n$error", textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => setState(() => _docRef = _makeRef()),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
            viewerOverlayBuilder: (context, size, handleLinkTap) => [
              PdfViewerScrollThumb(
                controller: _controller,
                orientation: horizontal ? ScrollbarOrientation.bottom : ScrollbarOrientation.right,
                thumbSize: horizontal ? const Size(56, 28) : const Size(44, 28),
                thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    controller.currentPageRange?.label ?? '${pageNumber ?? ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ],
            onPageChanged: (n) {
              if (n != null && n != _page) setState(() => _page = n);
            },
            onViewerReady: (document, controller) async {
              _searcher?.removeListener(_update);
              _searcher?.dispose();
              final searcher = PdfTextSearcher(controller)..addListener(_update);
              setState(() {
                _document = document;
                _searcher = searcher;
              });
              final outline = await document.loadOutline();
              if (mounted) setState(() => _outline = outline);
            },
          ),
        ),
      ),
    );
  }
}
