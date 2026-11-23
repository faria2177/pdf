import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// First-page thumbnails for the Recent list, cached as small PNGs on disk so the
/// list never keeps PDFs open. Password-protected files get no thumbnail (null).
class ThumbnailService {
  ThumbnailService._();

  static final _pending = <String, Future<File?>>{};
  static Directory? _dir;

  static Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationCacheDirectory();
    final d = Directory(p.join(base.path, 'thumbs'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return _dir = d;
  }

  static String _key(String path) {
    final f = File(path);
    final stamp = f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;
    return '${path.hashCode.toUnsigned(32).toRadixString(16)}_$stamp.png';
  }

  static Future<File?> thumbnailFor(String path, {int width = 180}) {
    return _pending.putIfAbsent(path, () async {
      try {
        final dir = await _cacheDir();
        final out = File(p.join(dir.path, _key(path)));
        if (out.existsSync()) return out;
        final doc = await PdfDocument.openFile(path); // no password provider: protected files fail
        try {
          if (doc.pages.isEmpty) return null;
          final page = doc.pages.first;
          final h = (width * page.height / page.width).round().clamp(1, width * 3);
          final rendered = await page.render(
            width: width,
            height: h,
            fullWidth: width.toDouble(),
            fullHeight: h.toDouble(),
            backgroundColor: 0xFFFFFFFF,
          );
          if (rendered == null) return null;
          try {
            final image = await rendered.createImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            if (png == null) return null;
            await out.writeAsBytes(png.buffer.asUint8List(), flush: true);
            return out;
          } finally {
            rendered.dispose();
          }
        } finally {
          await doc.dispose();
        }
      } catch (_) {
        return null;
      } finally {
        // Let a later call retry (e.g. after rename) instead of caching failures forever.
        Future.delayed(const Duration(seconds: 1), () => _pending.remove(path));
      }
    });
  }
}
