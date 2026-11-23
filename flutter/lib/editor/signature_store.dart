import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SignatureKind { signature, initials }

class SavedSignature {
  SavedSignature(this.file, this.kind);
  final File file;
  final SignatureKind kind;
}

/// Saved signatures/initials as transparent PNGs in app storage.
class SignatureStore {
  SignatureStore._();

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'signatures'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static Future<List<SavedSignature>> list() async {
    final d = await _dir();
    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return [
      for (final f in files)
        SavedSignature(f, p.basename(f.path).startsWith('ini_') ? SignatureKind.initials : SignatureKind.signature),
    ];
  }

  static Future<File> save(Uint8List png, SignatureKind kind) async {
    final d = await _dir();
    final prefix = kind == SignatureKind.initials ? 'ini_' : 'sig_';
    final f = File(p.join(d.path, '$prefix${DateTime.now().millisecondsSinceEpoch}.png'));
    await f.writeAsBytes(png, flush: true);
    return f;
  }

  static Future<void> delete(SavedSignature s) async {
    if (s.file.existsSync()) await s.file.delete();
  }
}
