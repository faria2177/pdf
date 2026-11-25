import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A file picked by the user, copied into app storage.
class PickedFile {
  PickedFile(this.path, this.name);
  final String path;
  final String name;

  bool get isPdf => name.toLowerCase().endsWith('.pdf');
}

class FileService {
  FileService._();

  static const imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'];

  static Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (cleaned.isEmpty) return 'document.pdf';
    return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
  }

  /// Copies bytes into the "library" folder (backing the recent-files list).
  static Future<String> storeInLibrary(Uint8List bytes, String name) async {
    final dir = await _dir('library');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, '${stamp}_${safeName(name)}'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Copies an existing file (e.g. from an "Open with" intent) into the library.
  static Future<String> importPath(String path, String name) async {
    final bytes = await File(path).readAsBytes();
    return storeInLibrary(bytes, name);
  }

  /// Display name for a library file (strips the timestamp prefix).
  static String displayName(String path) {
    final base = p.basename(path);
    final m = RegExp(r'^\d{10,}_(.+)$').firstMatch(base);
    return m?.group(1) ?? base;
  }

  static Future<List<PickedFile>> _pick({required bool pdf, required bool images, required bool multiple}) async {
    final List<PlatformFile> files;
    final ext = [if (pdf) 'pdf', if (images) ...imageExtensions];
    if (multiple) {
      files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ext);
    } else {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ext);
      files = f == null ? const [] : [f];
    }
    final result = <PickedFile>[];
    for (final f in files) {
      final bytes = await f.readAsBytes();
      final path = await storeInLibrary(bytes, f.name);
      result.add(PickedFile(path, f.name));
    }
    return result;
  }

  static Future<PickedFile?> pickPdf() async {
    final r = await _pick(pdf: true, images: false, multiple: false);
    return r.isEmpty ? null : r.first;
  }

  static Future<List<PickedFile>> pickPdfs() => _pick(pdf: true, images: false, multiple: true);

  static Future<List<PickedFile>> pickPdfsOrImages() => _pick(pdf: true, images: true, multiple: true);

  static Future<List<PickedFile>> pickImages() => _pick(pdf: false, images: true, multiple: true);

  /// Shows the system "Save as" dialog. Returns true when saved.
  static Future<bool> saveAs(Uint8List bytes, String fileName, {String mimeType = 'application/pdf'}) async {
    final uri = await FilePicker.saveFile(fileName: safeName(fileName), bytes: bytes, mimeType: mimeType);
    return uri != null;
  }

  /// Shares files under their real names. Data-only XFiles are written by
  /// the share plugin to random temp names, so the receiving app showed a
  /// different file name; here every file is written to its own folder with
  /// exactly the name the user sees.
  static Future<void> shareBytes(List<(Uint8List, String)> files, {String? mimeType}) async {
    final dir = await _shareDir();
    final xfiles = <XFile>[];
    final used = <String>{};
    for (final (bytes, name) in files) {
      final clean = _unique(safeName(name), used);
      final f = File(p.join(dir.path, clean));
      await f.writeAsBytes(bytes, flush: true);
      xfiles.add(XFile(f.path, name: clean, mimeType: mimeType ?? mimeFor(clean)));
    }
    await SharePlus.instance.share(ShareParams(files: xfiles));
  }

  /// Shares files already on disk under the given display names.
  static Future<void> shareFiles(List<(String, String)> files) async {
    final dir = await _shareDir();
    final xfiles = <XFile>[];
    final used = <String>{};
    for (final (path, name) in files) {
      final clean = _unique(safeName(name), used);
      final f = await File(path).copy(p.join(dir.path, clean));
      xfiles.add(XFile(f.path, name: clean, mimeType: mimeFor(clean)));
    }
    if (xfiles.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: xfiles));
  }

  static String _unique(String name, Set<String> used) {
    var out = name;
    var i = 2;
    while (!used.add(out.toLowerCase())) {
      out = '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}';
      i++;
    }
    return out;
  }

  /// A fresh folder per share; older ones are cleaned up.
  static Future<Directory> _shareDir() async {
    final root = Directory(p.join((await getTemporaryDirectory()).path, 'share_out'));
    if (root.existsSync()) {
      for (final e in root.listSync()) {
        try {
          if (DateTime.now().difference(e.statSync().modified).inHours >= 1) {
            e.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    }
    final dir = Directory(p.join(root.path, DateTime.now().microsecondsSinceEpoch.toString()));
    await dir.create(recursive: true);
    return dir;
  }

  static String mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
        '.pdf' => 'application/pdf',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        '.txt' => 'text/plain',
        '.zip' => 'application/zip',
        _ => 'application/octet-stream',
      };

  static String withoutExtension(String name) => p.basenameWithoutExtension(name);
}
