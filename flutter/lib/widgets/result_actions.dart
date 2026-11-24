import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../pages/home_page.dart';
import '../services/file_service.dart';
import '../services/recent_store.dart';
import 'dialogs.dart';

/// Share / Open / Save row for a finished file. The file is also added to Recent
/// as soon as it is shown.
class ResultActions extends StatefulWidget {
  const ResultActions({
    required this.bytes,
    required this.fileName,
    this.allowOpen = true,
    this.mimeType = 'application/pdf',
    super.key,
  });

  final Uint8List bytes;
  final String fileName;
  final bool allowOpen;
  final String mimeType;

  @override
  State<ResultActions> createState() => _ResultActionsState();
}

class _ResultActionsState extends State<ResultActions> {
  @override
  void initState() {
    super.initState();
    RecentStore.instance.addBytes(widget.bytes, widget.fileName);
  }

  @override
  void didUpdateWidget(covariant ResultActions old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes) || old.fileName != widget.fileName) {
      RecentStore.instance.addBytes(widget.bytes, widget.fileName);
    }
  }

  Uint8List get bytes => widget.bytes;
  String get fileName => widget.fileName;
  String get mimeType => widget.mimeType;
  bool get allowOpen => widget.allowOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => FileService.shareBytes([(bytes, fileName)], mimeType: mimeType),
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
        ),
        if (allowOpen) ...[
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final r = await RecentStore.instance.addBytes(bytes, fileName);
                if (context.mounted) await openPdfInViewer(context, r.path, name: r.name);
              },
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Open'),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            onPressed: () async {
              final ok = await FileService.saveAs(bytes, fileName, mimeType: mimeType);
              if (ok && context.mounted) toast(context, 'Saved $fileName');
            },
            icon: const Icon(Icons.save_alt),
            label: const Text('Save'),
          ),
        ),
      ],
    );
  }
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
}

/// Small header showing the chosen file.
class FileHeader extends StatelessWidget {
  const FileHeader({required this.name, required this.subtitle, this.icon = Icons.picture_as_pdf, super.key});
  final String name;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
    );
  }
}
