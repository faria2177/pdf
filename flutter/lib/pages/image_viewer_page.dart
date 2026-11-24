import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../services/file_service.dart';
import '../services/intent_service.dart';
import '../widgets/dialogs.dart';
import 'organize_page.dart';
import 'tools/resize_image_page.dart';

/// Full-screen image from Recent, with zoom and quick actions.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final mime = FileService.mimeFor(name);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share),
            onPressed: () async => FileService.shareBytes([(await file.readAsBytes(), name)], mimeType: mime),
          ),
          PopupMenuButton<String>(
            iconColor: Colors.white,
            onSelected: (v) async {
              switch (v) {
                case 'save':
                  final ok = await FileService.saveAs(await file.readAsBytes(), name, mimeType: mime);
                  if (ok && context.mounted) toast(context, 'Saved $name');
                case 'pdf':
                  if (!context.mounted) return;
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => OrganizePage(
                      sources: [PickedFile(path, name)],
                      title: 'Images to PDF',
                      outputName: '${FileService.withoutExtension(name)}.pdf',
                    ),
                  ));
                case 'resize':
                  if (!context.mounted) return;
                  await Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ResizeImagePage(files: [PickedFile(path, name)])));
                case 'open':
                  final ok = await IntentService.openWith(path, name, mime);
                  if (!ok && context.mounted) toast(context, 'No app found to open this file');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', child: Text('Save to device…')),
              PopupMenuItem(value: 'pdf', child: Text('Convert to PDF')),
              PopupMenuItem(value: 'resize', child: Text('Resize')),
              PopupMenuItem(value: 'open', child: Text('Open with…')),
            ],
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(child: Image.file(file, fit: BoxFit.contain)),
      ),
    );
  }
}
