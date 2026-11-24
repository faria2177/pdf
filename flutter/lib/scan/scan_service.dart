import 'dart:io';

import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/file_service.dart';

/// Camera capture with automatic edge detection and perspective correction (Google ML Kit).
/// Returns JPEG paths copied into app storage, or an empty list if cancelled.
class ScanService {
  ScanService._();

  static Future<List<String>> capture({int pageLimit = 100, bool allowGallery = true, bool fullEditor = false}) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        // "base" keeps the ML Kit screens short (capture + crop); our own editor does filters.
        mode: fullEditor ? ScannerMode.full : ScannerMode.base,
        pageLimit: pageLimit,
        isGalleryImport: allowGallery,
      ),
    );
    try {
      final result = await scanner.scanDocument();
      final images = result.images ?? const <String>[];
      if (images.isEmpty) return const [];
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'scans'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final out = <String>[];
      for (final (i, src) in images.indexed) {
        final path = src.startsWith('file://') ? Uri.parse(src).toFilePath() : src;
        final dst = p.join(dir.path, 'scan_${DateTime.now().microsecondsSinceEpoch}_$i.jpg');
        await File(path).copy(dst);
        out.add(dst);
      }
      return out;
    } catch (e) {
      final msg = '$e'.toLowerCase();
      if (msg.contains('cancel')) return const [];
      rethrow;
    } finally {
      scanner.close();
    }
  }

  static Future<Directory> _scanDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'scans'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Camera scanner first; if it can't start (no/old Google Play services, unsupported
  /// device), explains briefly and offers to continue with photos from the gallery.
  static Future<List<String>> captureOrPick(BuildContext context, {int pageLimit = 100}) async {
    Object? error;
    try {
      return await capture(pageLimit: pageLimit);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return const [];
    final pick = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.no_photography_outlined),
        title: const Text("Camera scanner couldn't start"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('It uses Google Play services. Make sure they are installed and up to date, '
                'or continue with photos you already took.'),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Details', style: TextStyle(fontSize: 13)),
              children: [
                SizedBox(
                  height: 120,
                  child: SingleChildScrollView(
                    child: SelectableText('$error'.split('\n').take(6).join('\n'), style: const TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(d, true),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose photos'),
          ),
        ],
      ),
    );
    if (pick != true) return const [];
    final files = await FileService.pickImages();
    if (files.isEmpty) return const [];
    final dir = await _scanDir();
    final out = <String>[];
    for (final (i, f) in files.take(pageLimit).indexed) {
      final dst = p.join(dir.path, 'pick_${DateTime.now().microsecondsSinceEpoch}_$i${p.extension(f.name).isEmpty ? '.jpg' : p.extension(f.name)}');
      await File(f.path).copy(dst);
      out.add(dst);
    }
    return out;
  }

  static void deleteQuietly(Iterable<String> paths) {
    for (final path in paths) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
