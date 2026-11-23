import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CompressResult {
  const CompressResult(this.bytes, this.images, this.replaced);
  final Uint8List bytes;
  final int images;
  final int replaced;
}

/// Compression presets: JPEG quality and the longest image side in pixels.
enum CompressLevel {
  light('Light', 'Best quality, small savings', 0.8, 2400),
  recommended('Recommended', 'Good quality, good savings', 0.6, 1600),
  strong('Strong', 'Smallest file, lower image quality', 0.4, 1000);

  const CompressLevel(this.label, this.description, this.quality, this.maxSide);
  final String label;
  final String description;
  final double quality;
  final int maxSide;
}

/// Calls PdfBox-Android (see PdfBoxChannel.kt) for encryption and image recompression.
class PdfBoxService {
  PdfBoxService._();

  static const _channel = MethodChannel('pdf_studio/pdfbox');

  static Future<String> _tempOut(String suffix) async {
    final dir = await getTemporaryDirectory();
    return p.join(dir.path, 'out_${DateTime.now().microsecondsSinceEpoch}_$suffix.pdf');
  }

  static Future<Uint8List> _readAndDelete(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    try {
      await f.delete();
    } catch (_) {}
    return bytes;
  }

  static String _message(PlatformException e) => e.message ?? e.code;

  /// Encrypts with AES-256. [password] opens the input if it is already protected.
  static Future<Uint8List> protect({
    required String input,
    required String userPassword,
    String? ownerPassword,
    String? password,
    bool allowPrint = true,
    bool allowCopy = true,
    bool allowModify = true,
  }) async {
    final out = await _tempOut('protected');
    try {
      await _channel.invokeMethod<Map>('protect', {
        'input': input,
        'output': out,
        'userPassword': userPassword,
        'ownerPassword': ownerPassword,
        'password': password,
        'allowPrint': allowPrint,
        'allowCopy': allowCopy,
        'allowModify': allowModify,
      });
    } on PlatformException catch (e) {
      throw Exception(_message(e));
    }
    return _readAndDelete(out);
  }

  static Future<CompressResult> compress({
    required String input,
    required CompressLevel level,
    String? password,
  }) async {
    final out = await _tempOut('compressed');
    Map? r;
    try {
      r = await _channel.invokeMethod<Map>('compress', {
        'input': input,
        'output': out,
        'quality': level.quality,
        'maxSide': level.maxSide,
        'password': password,
      });
    } on PlatformException catch (e) {
      throw Exception(_message(e));
    }
    final bytes = await _readAndDelete(out);
    return CompressResult(bytes, (r?['images'] as int?) ?? 0, (r?['replaced'] as int?) ?? 0);
  }
}
