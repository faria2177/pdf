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

  static Future<void> shareBytes(List<(Uint8List, String)> files, {String mimeType = 'application/pdf'}) async {
    final xfiles = [
      for (final (bytes, name) in files) XFile.fromData(bytes, name: safeName(name), mimeType: mimeType),
    ];
    await SharePlus.instance.share(ShareParams(files: xfiles));
  }

  static String withoutExtension(String name) => p.basenameWithoutExtension(name);
}
