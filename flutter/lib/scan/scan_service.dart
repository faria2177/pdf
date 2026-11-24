import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ds/screens/camera_screen.dart';
import '../ds/screens/id_card_templates.dart';

export '../ds/screens/id_card_templates.dart' show IdCardTemplate;

/// Opens DocScanner's camera (live green four-corner detection, auto/manual
/// shutter, batch mode, import from gallery, adjust corners) and returns the
/// cropped page images, copied into app storage. Empty when cancelled.
class ScanService {
  ScanService._();

  static Future<Directory> _scanDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'scans'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<List<String>> _keep(List<String>? paths) async {
    if (paths == null || paths.isEmpty) return const [];
    final dir = await _scanDir();
    final out = <String>[];
    for (final (i, src) in paths.indexed) {
      if (src.isEmpty || !File(src).existsSync()) continue;
      final ext = p.extension(src).isEmpty ? '.jpg' : p.extension(src);
      final dst = p.join(dir.path, 'scan_${DateTime.now().microsecondsSinceEpoch}_$i$ext');
      await File(src).copy(dst);
      out.add(dst);
    }
    return out;
  }

  /// Document scan (single or batch, chosen inside the camera).
  static Future<List<String>> scanDocuments(BuildContext context) async {
    final paths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => const CameraScreen()),
    );
    return _keep(paths);
  }

  /// Card scan: [sides] = 2 captures Front then Back in one camera session.
  static Future<List<String>> scanCard(
    BuildContext context, {
    required IdCardTemplate template,
    required int sides,
    String? side,
  }) async {
    final paths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          cardMode: true,
          cardTemplate: template,
          side: side ?? template.sideName(0),
          cardCaptureLimit: sides,
        ),
      ),
    );
    return _keep(paths);
  }

  /// Kept for callers that add or retake pages: opens the scanner and returns at
  /// most [pageLimit] pages.
  static Future<List<String>> captureOrPick(BuildContext context, {int pageLimit = 100}) async {
    final pages = await scanDocuments(context);
    if (pages.length <= pageLimit) return pages;
    deleteQuietly(pages.skip(pageLimit));
    return pages.take(pageLimit).toList();
  }

  static void deleteQuietly(Iterable<String> paths) {
    for (final path in paths) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
