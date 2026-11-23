import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/file_service.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';
import 'tool_base.dart';

enum ExportImageFormat { jpg, png }

class PdfToImagesPage extends StatefulWidget {
  const PdfToImagesPage({required this.path, required this.name, super.key});
  final String path;
  final String name;

  @override
  State<PdfToImagesPage> createState() => _PdfToImagesPageState();
}

class _PdfToImagesPageState extends PdfToolState<PdfToImagesPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  ExportImageFormat _format = ExportImageFormat.jpg;
  double _dpi = 150;
  double _quality = 90;
  bool _transparent = false;
  bool _grayscale = false;
  PageSelection _pages = const PageSelection.all();
  List<(Uint8List, String)>? _result;

  String get _ext => _format == ExportImageFormat.jpg ? 'jpg' : 'png';
  String get _mime => _format == ExportImageFormat.jpg ? 'image/jpeg' : 'image/png';

  Future<Uint8List> _render(PdfPage page) async {
    var scale = _dpi / 72;
    final longest = (page.width > page.height ? page.width : page.height) * scale;
    if (longest > 8000) scale *= 8000 / longest; // memory guard
    final w = (page.width * scale).round();
    final h = (page.height * scale).round();
    final transparent = _format == ExportImageFormat.png && _transparent;
    final r = await page.render(
      width: w,
      height: h,
      fullWidth: w.toDouble(),
      fullHeight: h.toDouble(),
      backgroundColor: transparent ? 0x00000000 : 0xFFFFFFFF,
    );
    if (r == null) throw Exception('Could not render page ${page.pageNumber}');
    ui.Image img;
    try {
      img = await r.createImage();
    } finally {
      r.dispose();
    }
    if (_grayscale) {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawImage(
        img,
        Offset.zero,
        ui.Paint()
          ..colorFilter = const ColorFilter.matrix([
            0.2126, 0.7152, 0.0722, 0, 0, //
            0.2126, 0.7152, 0.0722, 0, 0, //
            0.2126, 0.7152, 0.0722, 0, 0, //
            0, 0, 0, 1, 0,
          ]),
      );
      final g = await rec.endRecording().toImage(w, h);
      img.dispose();
      img = g;
    }
    try {
      if (_format == ExportImageFormat.png) {
        return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      }
      final rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      return await compute(_jpeg, (rgba, w, h, _quality.round()));
    } finally {
      img.dispose();
    }
  }

  Future<void> _convert() async {
    final pages = _pages.resolve(pageCount);
    final base = FileService.withoutExtension(widget.name);
    final digits = pageCount.toString().length;
    final out = await runWithProgress(context, 'Exporting images', (update) async {
      final files = <(Uint8List, String)>[];
      for (var i = 0; i < pages.length; i++) {
        update('Page ${pages[i]} (${i + 1} of ${pages.length})', (i + 1) / pages.length);
        final bytes = await _render(doc!.pages[pages[i] - 1]);
        files.add((bytes, '${base}_page${pages[i].toString().padLeft(digits, '0')}.$_ext'));
      }
      return files;
    });
    if (out != null && mounted) setState(() => _result = out);
  }

  Future<void> _saveZip() async {
    final files = _result!;
    final zip = await withProgress(context, 'Creating ZIP…', () async {
      final a = Archive();
      for (final (b, n) in files) {
        a.addFile(ArchiveFile(n, b.length, b));
      }
      return ZipEncoder().encodeBytes(a);
    });
    if (zip == null || !mounted) return;
    final name = '${FileService.withoutExtension(widget.name)}_images.zip';
    if (await FileService.saveAs(zip, name, mimeType: 'application/zip') && mounted) toast(context, 'Saved $name');
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _result = null;
      });

  @override
  Widget build(BuildContext context) {
    final err = doc == null ? null : _pages.error(pageCount);
    final first = doc == null || pageCount == 0 ? null : doc!.pages.first;
    final px = first == null ? '' : '${(first.width * _dpi / 72).round()} × ${(first.height * _dpi / 72).round()} px';
    final total = _result?.fold<int>(0, (s, f) => s + f.$1.length) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('PDF to JPG')),
      body: doc == null
          ? loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                header(),
                const SectionTitle('Format'),
                SegmentedButton<ExportImageFormat>(
                  segments: const [
                    ButtonSegment(value: ExportImageFormat.jpg, label: Text('JPG'), icon: Icon(Icons.photo_outlined)),
                    ButtonSegment(value: ExportImageFormat.png, label: Text('PNG (lossless)'), icon: Icon(Icons.image_outlined)),
                  ],
                  selected: {_format},
                  onSelectionChanged: (s) => _changed(() => _format = s.first),
                ),
                const SectionTitle('Resolution'),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 72, label: Text('Screen\n72 dpi', textAlign: TextAlign.center)),
                    ButtonSegment(value: 150, label: Text('Standard\n150 dpi', textAlign: TextAlign.center)),
                    ButtonSegment(value: 300, label: Text('Print\n300 dpi', textAlign: TextAlign.center)),
                  ],
                  selected: {if (const [72.0, 150.0, 300.0].contains(_dpi)) _dpi},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (s) {
                    if (s.isNotEmpty) _changed(() => _dpi = s.first);
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _dpi,
                        min: 50,
                        max: 600,
                        divisions: 55,
                        label: '${_dpi.round()} dpi',
                        onChanged: (v) => _changed(() => _dpi = v.roundToDouble()),
                      ),
                    ),
                    SizedBox(width: 72, child: Text('${_dpi.round()} dpi', textAlign: TextAlign.end)),
                  ],
                ),
                if (px.isNotEmpty) Text('Page 1 → $px', style: Theme.of(context).textTheme.bodySmall),
                if (_format == ExportImageFormat.jpg) ...[
                  const SectionTitle('JPG quality'),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _quality,
                          min: 40,
                          max: 100,
                          divisions: 12,
                          label: '${_quality.round()}%',
                          onChanged: (v) => _changed(() => _quality = v),
                        ),
                      ),
                      SizedBox(width: 48, child: Text('${_quality.round()}%', textAlign: TextAlign.end)),
                    ],
                  ),
                ],
                const SectionTitle('Pages'),
                PageRangeSelector(pageCount: pageCount, value: _pages, onChanged: (v) => _changed(() => _pages = v)),
                const SectionTitle('Options'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Black & white'),
                  subtitle: const Text('Grayscale output, smaller files'),
                  value: _grayscale,
                  onChanged: (v) => _changed(() => _grayscale = v),
                ),
                if (_format == ExportImageFormat.png)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Transparent background'),
                    value: _transparent,
                    onChanged: (v) => _changed(() => _transparent = v),
                  ),
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: err == null ? _convert : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(err ?? 'Convert to ${_ext.toUpperCase()}'),
                  )
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: Text('${_result!.length} image${_result!.length == 1 ? '' : 's'} ready'),
                    subtitle: Text(formatBytes(total)),
                  ),
                  SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _result!.length.clamp(0, 30),
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(_result![i].$1, height: 120, fit: BoxFit.contain, cacheHeight: 240),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_result!.length == 1)
                    ResultActions(bytes: _result!.first.$1, fileName: _result!.first.$2, allowOpen: false, mimeType: _mime)
                  else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => FileService.shareBytes(_result!, mimeType: _mime),
                            icon: const Icon(Icons.share),
                            label: const Text('Share all'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _saveZip,
                            icon: const Icon(Icons.folder_zip_outlined),
                            label: const Text('Save ZIP'),
                          ),
                        ),
                      ],
                    ),
                ],
              ],
            ),
    );
  }
}

Uint8List _jpeg((Uint8List, int, int, int) a) {
  final (rgba, w, h, q) = a;
  return JpegEncoder().compress(rgba, w, h, q);
}
