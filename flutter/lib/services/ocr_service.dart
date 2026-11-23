import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

class OcrLanguage {
  const OcrLanguage(this.code, this.name, this.native);
  final String code;
  final String name;
  final String native;
}

const ocrLanguages = <OcrLanguage>[
  OcrLanguage('eng', 'English', 'English'),
  OcrLanguage('ben', 'Bengali', 'বাংলা'),
  OcrLanguage('hin', 'Hindi', 'हिन्दी'),
  OcrLanguage('ara', 'Arabic', 'العربية'),
  OcrLanguage('urd', 'Urdu', 'اردو'),
  OcrLanguage('fra', 'French', 'Français'),
  OcrLanguage('deu', 'German', 'Deutsch'),
  OcrLanguage('spa', 'Spanish', 'Español'),
  OcrLanguage('por', 'Portuguese', 'Português'),
  OcrLanguage('ita', 'Italian', 'Italiano'),
  OcrLanguage('rus', 'Russian', 'Русский'),
  OcrLanguage('tur', 'Turkish', 'Türkçe'),
  OcrLanguage('ind', 'Indonesian', 'Bahasa Indonesia'),
  OcrLanguage('chi_sim', 'Chinese (Simplified)', '简体中文'),
  OcrLanguage('jpn', 'Japanese', '日本語'),
  OcrLanguage('kor', 'Korean', '한국어'),
];

enum OcrModel {
  fast('Fast', 'Smaller download, quick', 'tessdata_fast'),
  best('Best accuracy', 'Larger download, slower, more accurate', 'tessdata_best');

  const OcrModel(this.label, this.description, this.repo);
  final String label;
  final String description;
  final String repo;
}

class OcrPageText {
  const OcrPageText(this.text, this.confidence);
  final String text;
  final int confidence;
}

/// Tesseract OCR (native side: OcrChannel.kt). Language files are downloaded once from the
/// official tesseract-ocr GitHub repositories and kept in app storage.
class OcrService {
  OcrService._();

  static const _channel = MethodChannel('pdf_studio/ocr');
  static void Function(int done, int total)? _onProgress;

  static void _ensureHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is Map) {
        final m = call.arguments as Map;
        _onProgress?.call((m['done'] as num).toInt(), (m['total'] as num).toInt());
      }
      return null;
    });
  }

  static Future<Directory> _root(OcrModel model) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'tesseract_${model.name}'));
    final data = Directory(p.join(d.path, 'tessdata'));
    if (!data.existsSync()) data.createSync(recursive: true);
    // Glyph-less font the searchable-PDF renderer needs.
    for (final dir in [d, data]) {
      final ttf = File(p.join(dir.path, 'pdf.ttf'));
      if (!ttf.existsSync()) {
        final bytes = await rootBundle.load('assets/tess/pdf.ttf');
        await ttf.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
    }
    return d;
  }

  static Future<bool> isInstalled(String code, OcrModel model) async {
    final d = await _root(model);
    final f = File(p.join(d.path, 'tessdata', '$code.traineddata'));
    return f.existsSync() && f.lengthSync() > 1000;
  }

  static Future<int> installedSize(String code, OcrModel model) async {
    final d = await _root(model);
    final f = File(p.join(d.path, 'tessdata', '$code.traineddata'));
    return f.existsSync() ? f.lengthSync() : 0;
  }

  static Future<void> delete(String code, OcrModel model) async {
    final d = await _root(model);
    final f = File(p.join(d.path, 'tessdata', '$code.traineddata'));
    if (f.existsSync()) await f.delete();
  }

  /// Downloads `<code>.traineddata`, reporting progress 0..1.
  static Future<void> download(String code, OcrModel model, {void Function(double)? onProgress}) async {
    final d = await _root(model);
    final target = File(p.join(d.path, 'tessdata', '$code.traineddata'));
    final tmp = File('${target.path}.part');
    final url = Uri.parse('https://github.com/tesseract-ocr/${model.repo}/raw/main/$code.traineddata');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(url);
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode})', uri: url);
      final total = res.contentLength;
      var got = 0;
      final sink = tmp.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
      await sink.close();
      if (tmp.lengthSync() < 1000) throw const FileSystemException('Downloaded file is empty');
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Renders the chosen pages to JPEG files for Tesseract.
  static Future<List<String>> renderPages(
    PdfDocument doc,
    List<int> pageNumbers, {
    int dpi = 300,
    void Function(int done, int total)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'ocr_${DateTime.now().microsecondsSinceEpoch}'));
    dir.createSync(recursive: true);
    final paths = <String>[];
    for (var i = 0; i < pageNumbers.length; i++) {
      final page = doc.pages[pageNumbers[i] - 1];
      var scale = dpi / 72;
      // Keep very large pages within memory limits.
      final longest = (page.width > page.height ? page.width : page.height) * scale;
      if (longest > 4200) scale *= 4200 / longest;
      final w = (page.width * scale).round();
      final h = (page.height * scale).round();
      final rendered = await page.render(
        width: w,
        height: h,
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) throw Exception('Could not render page ${pageNumbers[i]}');
      final Uint8List rgba;
      try {
        final img = await rendered.createImage();
        rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        img.dispose();
      } finally {
        rendered.dispose();
      }
      final jpeg = await compute(_encodeJpeg, (rgba, w, h));
      final path = p.join(dir.path, 'page_${pageNumbers[i].toString().padLeft(4, '0')}.jpg');
      await File(path).writeAsBytes(jpeg, flush: true);
      paths.add(path);
      onProgress?.call(i + 1, pageNumbers.length);
    }
    return paths;
  }

  static Future<String> _dataPath(OcrModel model) async => (await _root(model)).path;

  /// Searchable PDF (page image + invisible text). Returns the output file path.
  static Future<String> toSearchablePdf({
    required List<String> images,
    required List<String> languages,
    required OcrModel model,
    required int dpi,
    String title = 'OCR',
    void Function(int done, int total)? onProgress,
  }) async {
    _ensureHandler();
    _onProgress = onProgress;
    final tmp = await getTemporaryDirectory();
    final out = p.join(tmp.path, 'ocr_out_${DateTime.now().microsecondsSinceEpoch}');
    try {
      final path = await _channel.invokeMethod<String>('ocrToPdf', {
        'dataPath': await _dataPath(model),
        'lang': languages.join('+'),
        'images': images,
        'output': out,
        'title': title,
        'dpi': dpi,
      });
      return path!;
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      _onProgress = null;
    }
  }

  static Future<List<OcrPageText>> toText({
    required List<String> images,
    required List<String> languages,
    required OcrModel model,
    required int dpi,
    void Function(int done, int total)? onProgress,
  }) async {
    _ensureHandler();
    _onProgress = onProgress;
    try {
      final r = await _channel.invokeMethod<List>('ocrToText', {
        'dataPath': await _dataPath(model),
        'lang': languages.join('+'),
        'images': images,
        'dpi': dpi,
      });
      return [
        for (final e in r ?? const [])
          OcrPageText((e as Map)['text'] as String? ?? '', (e['confidence'] as num?)?.toInt() ?? 0),
      ];
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      _onProgress = null;
    }
  }

  /// Remembered language choice and model.
  static Future<(List<String>, OcrModel)> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final langs = prefs.getStringList('ocr_langs') ?? const ['eng'];
    final model = OcrModel.values.firstWhere((m) => m.name == prefs.getString('ocr_model'), orElse: () => OcrModel.fast);
    return (langs, model);
  }

  static Future<void> savePrefs(List<String> langs, OcrModel model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ocr_langs', langs);
    await prefs.setString('ocr_model', model.name);
  }

  /// Codes from [langs] whose data is not downloaded yet.
  static Future<List<String>> missing(List<String> langs, OcrModel model) async => [
        for (final l in langs)
          if (!await isInstalled(l, model)) l,
      ];

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  static void cleanup(List<String> images) {
    if (images.isEmpty) return;
    try {
      File(images.first).parent.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Uint8List _encodeJpeg((Uint8List, int, int) a) {
  final (rgba, w, h) = a;
  return JpegEncoder().compress(rgba, w, h, 85);
}
