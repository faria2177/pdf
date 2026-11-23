import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../pages/home_page.dart';
import '../services/file_service.dart';
import 'dialogs.dart';

/// Share / Open / Save row for a finished PDF.
class ResultActions extends StatelessWidget {
  const ResultActions({required this.bytes, required this.fileName, this.allowOpen = true, super.key});

  final Uint8List bytes;
  final String fileName;
  final bool allowOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => FileService.shareBytes([(bytes, fileName)]),
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
        ),
        if (allowOpen) ...[
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final path = await FileService.storeInLibrary(bytes, fileName);
                if (context.mounted) await openPdfInViewer(context, path, name: fileName);
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
              final ok = await FileService.saveAs(bytes, fileName);
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
