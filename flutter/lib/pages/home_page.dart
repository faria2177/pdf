import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../services/intent_service.dart';
import '../services/recent_store.dart';
import '../widgets/dialogs.dart';

import '../editor/pdf_editor_page.dart';
import '../scan/id_card_page.dart';
import '../scan/scan_review_page.dart';
import '../scan/scan_service.dart';
import '../services/thumbnail_service.dart';
import 'compress_page.dart';
import 'image_viewer_page.dart';
import 'tools/extract_text_page.dart';
import 'tools/ocr_page.dart';
import 'tools/pdf_to_excel_page.dart';
import 'tools/pdf_to_images_page.dart';
import 'tools/pdf_to_word_page.dart';
import 'tools/resize_image_page.dart';
import 'organize_page.dart';
import 'protect_page.dart';
import 'redact_page.dart';
import 'split_page.dart';
import 'viewer_page.dart';

/// Opens [path] in the viewer. Files from outside the app's library are copied in first
/// so they can be reopened later from "Recent".
Future<void> openPdfInViewer(BuildContext context, String path, {String? name}) async {
  final displayName = name ?? FileService.displayName(path);
  var libPath = path;
  if (!path.contains('/library/')) {
    try {
      libPath = await FileService.importPath(path, displayName);
    } catch (e) {
      if (context.mounted) toast(context, "Couldn't open: $e");
      return;
    }
  }
  await RecentStore.instance.add(libPath, displayName);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewerPage(path: libPath, name: displayName)));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    RecentStore.instance.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = IntentService.instance.takePending();
      if (pending != null && mounted) openPdfInViewer(context, pending);
    });
  }

  @override
  void dispose() {
    RecentStore.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    final f = await FileService.pickPdf();
    if (f == null || !mounted) return;
    await RecentStore.instance.add(f.path, f.name);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewerPage(path: f.path, name: f.name)));
  }

  Future<void> _organize() async {
    final f = await FileService.pickPdf();
    if (f == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrganizePage(sources: [f], title: 'Organize pages', outputName: f.name),
    ));
  }

  Future<void> _combine() async {
    final files = await FileService.pickPdfsOrImages();
    if (files.isEmpty || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrganizePage(sources: files, title: 'Combine files', outputName: 'Combined.pdf'),
    ));
  }

  Future<void> _images() async {
    final files = await FileService.pickImages();
    if (files.isEmpty || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrganizePage(sources: files, title: 'Images to PDF', outputName: 'Images.pdf'),
    ));
  }

  Future<void> _split({required bool extract}) async {
    final f = await FileService.pickPdf();
    if (f == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SplitPage(path: f.path, name: f.name, extractMode: extract),
    ));
  }

  /// Picks a PDF, then opens [builder]'s page for it.
  Future<void> _pickThen(Widget Function(String path, String name) builder) async {
    final f = await FileService.pickPdf();
    if (f == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => builder(f.path, f.name)));
  }

  Future<void> _scan() async {
    try {
      final images = await ScanService.capture();
      if (images.isEmpty || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanReviewPage(images: images)));
    } catch (e) {
      if (!mounted) return;
      toast(context, "Scanner unavailable: ${'$e'.replaceFirst('Exception: ', '')}. It needs Google Play services.");
    }
  }

  Future<void> _idCard() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IdCardPage()));
  }

  void _more() {
    void go(Widget Function(String, String) page) => _pickThen(page);
    final sections = <(String, List<_Tool>)>[
      (
        'Convert',
        [
          _Tool(Icons.image_outlined, 'Images to PDF', '', _images),
          _Tool(Icons.description_outlined, 'PDF to Word', '', () => go((p, n) => PdfToWordPage(path: p, name: n))),
          _Tool(Icons.table_chart_outlined, 'PDF to Excel', '', () => go((p, n) => PdfToExcelPage(path: p, name: n))),
          _Tool(Icons.photo_library_outlined, 'PDF to JPG', '', () => go((p, n) => PdfToImagesPage(path: p, name: n))),
          _Tool(Icons.text_snippet_outlined, 'Extract text', '', () => go((p, n) => ExtractTextPage(path: p, name: n))),
        ]
      ),
      (
        'Edit & sign',
        [
          _Tool(Icons.edit_document, 'Edit PDF', '', () => go((p, n) => PdfEditorPage(path: p, name: n))),
          _Tool(Icons.draw_outlined, 'Sign PDF', '',
              () => go((p, n) => PdfEditorPage(path: p, name: n, mode: EditorMode.sign))),
          _Tool(Icons.format_color_fill, 'Redact PDF', '', () => go((p, n) => RedactPage(path: p, name: n))),
          _Tool(Icons.document_scanner_outlined, 'OCR PDF', '', () => go((p, n) => OcrPage(path: p, name: n))),
        ]
      ),
      (
        'Optimize & secure',
        [
          _Tool(Icons.compress, 'Compress PDF', '', () => go((p, n) => CompressPage(path: p, name: n))),
          _Tool(Icons.lock_outline, 'Protect PDF', '', () => go((p, n) => ProtectPage(path: p, name: n))),
          _Tool(Icons.content_cut, 'Extract pages', '', () => _split(extract: true)),
          _Tool(Icons.photo_size_select_large, 'Resize image', '', _resizeImages),
        ]
      ),
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        final scheme = Theme.of(sheet).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.95,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text('All tools', style: Theme.of(sheet).textTheme.titleLarge),
              for (final (title, tools) in sections) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 18, bottom: 8),
                  child: Text(title.toUpperCase(),
                      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.8)),
                ),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.82,
                  children: [
                    for (final t in tools)
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          Navigator.pop(sheet);
                          t.onTap();
                        },
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(t.icon, color: scheme.onPrimaryContainer, size: 26),
                            ),
                            const SizedBox(height: 6),
                            Text(t.title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _resizeImages() async {
    final files = await FileService.pickImages();
    if (files.isEmpty || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResizeImagePage(files: files)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final exit = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            icon: const Icon(Icons.exit_to_app),
            title: const Text('Exit PDF Studio?'),
            content: const Text('Your files stay in Recent.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Exit')),
            ],
          ),
        );
        if (exit == true) await SystemNavigator.pop();
      },
      child: _buildHome(context),
    );
  }

  Widget _buildHome(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = RecentStore.instance.items;
    final tools = <_Tool>[
      _Tool(Icons.document_scanner, 'Scan', 'Filters, crop, multi-page', _scan),
      _Tool(Icons.badge_outlined, 'ID Card', 'Front & back on one page', _idCard),
      _Tool(Icons.dashboard_customize_outlined, 'Organize pages', 'Reorder, rotate, delete, insert', _organize),
      _Tool(Icons.merge_type, 'Combine files', 'Merge PDFs and images', _combine),
      _Tool(Icons.call_split, 'Split PDF', 'Every N pages or by ranges', () => _split(extract: false)),
      _Tool(Icons.apps, 'More', 'Images to PDF, Word, Excel, sign…', _more),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Studio'),
        actions: [
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'PDF Studio',
              applicationVersion: '1.0',
              children: const [
                Text('A private, offline PDF reader and page organizer. '
                    'Inspired by the feature set of the open-source PdfCraft project; '
                    'rendering by PDFium through pdfrx. Nothing leaves your phone.'),
              ],
            ),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Card(
                color: scheme.primaryContainer,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _open,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Icon(Icons.picture_as_pdf, size: 44, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Open PDF',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: scheme.onPrimaryContainer)),
                              Text('Read, search, bookmarks, thumbnails',
                                  style: TextStyle(color: scheme.onPrimaryContainer)),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
            sliver: SliverToBoxAdapter(child: Text('Tools', style: TextStyle(fontWeight: FontWeight.w600))),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 96,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _ToolCard(tool: tools[i]),
                childCount: tools.length,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 4),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  const Expanded(child: Text('Recent', style: TextStyle(fontWeight: FontWeight.w600))),
                  if (recent.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        if (await confirm(context, 'Remove all recent files from this app?', ok: 'Clear')) {
                          await RecentStore.instance.clear();
                        }
                      },
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
          ),
          if (recent.isEmpty)
            const SliverPadding(
              padding: EdgeInsets.all(24),
              sliver: SliverToBoxAdapter(
                child: Center(child: Text('Files you open appear here.', style: TextStyle(color: Colors.grey))),
              ),
            )
          else
            SliverList.builder(
              itemCount: recent.length,
              itemBuilder: (context, i) {
                final r = recent[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: _RecentThumb(key: ValueKey(r.path), item: r),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${r.ext.toUpperCase()} · ${_size(r.path)}${_ago(r.openedAt)}'),
                  onTap: () => _openRecent(r),
                  onLongPress: () => _recentActions(r),
                  trailing: IconButton(
                    tooltip: 'Options',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _recentActions(r),
                  ),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  static String _size(String path) {
    try {
      final b = File(path).lengthSync();
      final s = b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
      return '$s · ';
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------- recent item actions

  void _recentActions(RecentFile r) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(r.name,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(sheet).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(sheet);
                _rename(r);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open with another app'),
              onTap: () {
                Navigator.pop(sheet);
                _openExternally(r);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(sheet);
                _shareRecent(r);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheet);
                _delete(r);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(RecentFile r) async {
    final current = FileService.withoutExtension(r.name);
    final v = await askText(context, title: 'Rename', initial: current, hint: 'File name', okLabel: 'Rename');
    final name = v?.trim() ?? '';
    if (name.isEmpty || name == current || !mounted) return;
    try {
      final updated = await RecentStore.instance.rename(r, name);
      if (mounted) toast(context, 'Renamed to ${updated.name}');
    } catch (e) {
      if (mounted) toast(context, "Couldn't rename: $e");
    }
  }

  /// PDFs open in the viewer, images in the image viewer, everything else
  /// (Word, Excel, text, ZIP) in another installed app.
  Future<void> _openRecent(RecentFile r) async {
    if (!File(r.path).existsSync()) {
      toast(context, 'File not found');
      await RecentStore.instance.remove(r, deleteFile: false);
      return;
    }
    if (r.isPdf) {
      await openPdfInViewer(context, r.path, name: r.name);
    } else if (r.isImage) {
      await RecentStore.instance.add(r.path, r.name);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewerPage(path: r.path, name: r.name)));
    } else {
      await _openExternally(r);
    }
  }

  Future<void> _openExternally(RecentFile r) async {
    final ok = await IntentService.openWith(r.path, r.name, FileService.mimeFor(r.name));
    if (!ok && mounted) {
      toast(context, 'No app found to open .${r.ext} files. Try Share instead.');
    }
  }

  Future<void> _shareRecent(RecentFile r) async {
    final f = File(r.path);
    if (!f.existsSync()) {
      toast(context, 'File not found');
      await RecentStore.instance.remove(r, deleteFile: false);
      return;
    }
    try {
      await FileService.shareBytes([(await f.readAsBytes(), r.name)], mimeType: FileService.mimeFor(r.name));
    } catch (e) {
      if (mounted) toast(context, "Couldn't share: $e");
    }
  }

  Future<void> _delete(RecentFile r) async {
    final ok = await confirm(
      context,
      '"${r.name}" will be deleted from this app. '
      'The original file you opened (in Downloads, WhatsApp, etc.) is not touched.',
      ok: 'Delete',
      title: 'Delete file?',
    );
    if (!ok) return;
    await RecentStore.instance.remove(r);
    if (mounted) toast(context, 'Deleted ${r.name}');
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 30) return '${d.inDays} d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

class _Tool {
  const _Tool(this.icon, this.title, this.subtitle, this.onTap);
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool});
  final _Tool tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tool.onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(tool.icon, color: scheme.primary, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tool.title, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1),
                    const SizedBox(height: 2),
                    Text(tool.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Preview for a Recent entry: first page for PDFs, the picture for images, a file badge otherwise.
class _RecentThumb extends StatefulWidget {
  const _RecentThumb({required this.item, super.key});
  final RecentFile item;

  @override
  State<_RecentThumb> createState() => _RecentThumbState();
}

class _RecentThumbState extends State<_RecentThumb> {
  late final Future<File?>? _thumb = widget.item.isPdf ? ThumbnailService.thumbnailFor(widget.item.path) : null;

  Widget _badge(ColorScheme scheme) {
    final (icon, color) = switch (widget.item.ext) {
      'docx' || 'doc' => (Icons.description, const Color(0xFF2B579A)),
      'xlsx' || 'xls' => (Icons.table_chart, const Color(0xFF217346)),
      'txt' => (Icons.notes, const Color(0xFF616161)),
      'zip' => (Icons.folder_zip, const Color(0xFFF57C00)),
      _ => (Icons.insert_drive_file, scheme.outline),
    };
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 24),
        Text(widget.item.ext.toUpperCase(),
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget child;
    if (widget.item.isImage) {
      child = Image.file(File(widget.item.path), fit: BoxFit.cover, cacheWidth: 120, gaplessPlayback: true,
          errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: scheme.outline));
    } else if (widget.item.isPdf) {
      child = FutureBuilder<File?>(
        future: _thumb,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)));
          }
          final f = snap.data;
          if (f == null) return Icon(Icons.lock_outline, size: 20, color: scheme.outline);
          return Image.file(f, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true);
        },
      );
    } else {
      child = _badge(scheme);
    }
    return Container(
      width: 44,
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
