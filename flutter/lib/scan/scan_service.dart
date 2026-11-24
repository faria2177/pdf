import 'dart:io';

import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  static void deleteQuietly(Iterable<String> paths) {
    for (final path in paths) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
