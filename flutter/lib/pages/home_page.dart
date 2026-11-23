import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../services/intent_service.dart';
import '../services/recent_store.dart';
import '../widgets/dialogs.dart';
import 'organize_page.dart';
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = RecentStore.instance.items;
    final tools = <_Tool>[
      _Tool(Icons.dashboard_customize_outlined, 'Organize pages', 'Reorder, rotate, delete, insert', _organize),
      _Tool(Icons.merge_type, 'Combine files', 'Merge PDFs and images', _combine),
      _Tool(Icons.call_split, 'Split PDF', 'Every N pages or by ranges', () => _split(extract: false)),
      _Tool(Icons.content_cut, 'Extract pages', 'Copy chosen pages to a new PDF', () => _split(extract: true)),
      _Tool(Icons.image_outlined, 'Images to PDF', 'Photos and scans to one PDF', _images),
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
                  leading: const Icon(Icons.description_outlined),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_ago(r.openedAt)),
                  onTap: () => openPdfInViewer(context, r.path, name: r.name),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: () => RecentStore.instance.remove(r),
                  ),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
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
