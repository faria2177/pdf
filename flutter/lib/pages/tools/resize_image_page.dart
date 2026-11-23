import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:jpeg_encode/jpeg_encode.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/file_service.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/result_actions.dart';
import '../../widgets/tool_widgets.dart';

enum ResizeMode { percent, dimensions, fileSize, preset }

enum OutFormat { same, jpg, png }

class _Preset {
  const _Preset(this.label, this.w, this.h);
  final String label;
  final int w;
  final int h;
}

const _presets = [
  _Preset('Passport 35×45 mm', 413, 531),
  _Preset('Square 1080', 1080, 1080),
  _Preset('Story 1080×1920', 1080, 1920),
  _Preset('HD 1280×720', 1280, 720),
  _Preset('Full HD 1920×1080', 1920, 1080),
  _Preset('4K 3840×2160', 3840, 2160),
  _Preset('Email 1024 px', 1024, 1024),
  _Preset('Web 1600 px', 1600, 1600),
];

class _Src {
  _Src(this.path, this.name, this.bytes, this.width, this.height);
  final String path;
  final String name;
  final Uint8List bytes;
  final int width;
  final int height;
  bool get isPng => name.toLowerCase().endsWith('.png');
}

class _Out {
  _Out(this.bytes, this.name, this.width, this.height, this.src);
  final Uint8List bytes;
  final String name;
  final int width;
  final int height;
  final _Src src;
}

class ResizeImagePage extends StatefulWidget {
  const ResizeImagePage({required this.files, super.key});
  final List<PickedFile> files;

  @override
  State<ResizeImagePage> createState() => _ResizeImagePageState();
}

class _ResizeImagePageState extends State<ResizeImagePage> {
  final _srcs = <_Src>[];
  bool _loading = true;
  ResizeMode _mode = ResizeMode.percent;
  OutFormat _format = OutFormat.same;
  double _percent = 50;
  final _w = TextEditingController(text: '1280');
  final _h = TextEditingController(text: '1280');
  final _kb = TextEditingController(text: '200');
  bool _keepAspect = true;
  bool _noEnlarge = true;
  _Preset _preset = _presets[1];
  double _quality = 85;
  List<_Out>? _result;

  @override
  void initState() {
    super.initState();
    _load(widget.files);
  }

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    _kb.dispose();
    super.dispose();
  }

  Future<void> _load(List<PickedFile> files) async {
    setState(() => _loading = true);
    for (final f in files) {
      try {
        final bytes = await File(f.path).readAsBytes();
        final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
        final desc = await ui.ImageDescriptor.encoded(buf);
        _srcs.add(_Src(f.path, f.name, bytes, desc.width, desc.height));
        desc.dispose();
        buf.dispose();
      } catch (e) {
        if (mounted) toast(context, '${f.name}: not a supported image');
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = null;
    });
    if (_srcs.isEmpty) Navigator.of(context).maybePop();
  }

  Future<void> _addMore() async {
    final files = await FileService.pickImages();
    if (files.isNotEmpty) await _load(files);
  }

  /// Target size for one image under the current settings.
  (int, int) _targetSize(_Src s) {
    double w = s.width.toDouble(), h = s.height.toDouble();
    switch (_mode) {
      case ResizeMode.percent:
        w *= _percent / 100;
        h *= _percent / 100;
      case ResizeMode.dimensions:
      case ResizeMode.preset:
        final tw = _mode == ResizeMode.preset ? _preset.w.toDouble() : (double.tryParse(_w.text) ?? w);
        final th = _mode == ResizeMode.preset ? _preset.h.toDouble() : (double.tryParse(_h.text) ?? h);
        if (_keepAspect || _mode == ResizeMode.preset) {
          var scale = math.min(tw / w, th / h);
          if (_noEnlarge) scale = math.min(scale, 1);
          w *= scale;
          h *= scale;
        } else {
          w = _noEnlarge ? math.min(tw, w) : tw;
          h = _noEnlarge ? math.min(th, h) : th;
        }
      case ResizeMode.fileSize:
        break; // starts at full size, shrinks if needed
    }
    return (math.max(1, w.round()), math.max(1, h.round()));
  }

  bool _asPng(_Src s) =>
      _mode != ResizeMode.fileSize && (_format == OutFormat.png || (_format == OutFormat.same && s.isPng));

  Future<Uint8List> _rgba(_Src s, int w, int h) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(s.bytes);
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buf,
      getTargetSize: (_, _) => ui.TargetImageSize(width: w, height: h),
    );
    try {
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      return data!.buffer.asUint8List();
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _png(_Src s, int w, int h) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(s.bytes);
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buf,
      getTargetSize: (_, _) => ui.TargetImageSize(width: w, height: h),
    );
    try {
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data!.buffer.asUint8List();
    } finally {
      codec.dispose();
    }
  }

  Future<_Out> _process(_Src s) async {
    var (w, h) = _targetSize(s);
    final base = FileService.withoutExtension(s.name);
    if (_asPng(s)) {
      final png = await _png(s, w, h);
      return _Out(png, '${base}_${w}x$h.png', w, h, s);
    }
    if (_mode != ResizeMode.fileSize) {
      final jpg = await compute(_jpegFromRgba, (await _rgba(s, w, h), w, h, _quality.round()));
      return _Out(jpg, '${base}_${w}x$h.jpg', w, h, s);
    }
    // Target file size: lower quality first, then dimensions.
    final target = ((double.tryParse(_kb.text) ?? 200) * 1024).round();
    Uint8List? best;
    for (var round = 0; round < 8; round++) {
      final rgba = await _rgba(s, w, h);
      for (final q in const [92, 85, 78, 70, 62, 54, 46, 38]) {
        final jpg = await compute(_jpegFromRgba, (rgba, w, h, q));
        best = jpg;
        if (jpg.length <= target) return _Out(jpg, '${base}_${(jpg.length / 1024).round()}KB.jpg', w, h, s);
      }
      w = math.max(1, (w * 0.8).round());
      h = math.max(1, (h * 0.8).round());
    }
    return _Out(best!, '${base}_${(best.length / 1024).round()}KB.jpg', w, h, s);
  }

  Future<void> _run() async {
    final out = await runWithProgress(context, 'Resizing', (update) async {
      final res = <_Out>[];
      for (var i = 0; i < _srcs.length; i++) {
        update('${_srcs[i].name} (${i + 1} of ${_srcs.length})', (i + 1) / _srcs.length);
        res.add(await _process(_srcs[i]));
      }
      return res;
    });
    if (out != null && mounted) setState(() => _result = out);
  }

  Future<void> _saveZip() async {
    final a = Archive();
    for (final o in _result!) {
      a.addFile(ArchiveFile(o.name, o.bytes.length, o.bytes));
    }
    final zip = ZipEncoder().encodeBytes(a);
    if (await FileService.saveAs(zip, 'resized_images.zip', mimeType: 'application/zip') && mounted) {
      toast(context, 'Saved resized_images.zip');
    }
  }

  String _mime(String name) => name.endsWith('.png') ? 'image/png' : 'image/jpeg';

  void _changed(VoidCallback f) => setState(() {
        f();
        _result = null;
      });

  Widget _modeOptions() {
    switch (_mode) {
      case ResizeMode.percent:
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _percent,
                    min: 5,
                    max: 100,
                    divisions: 19,
                    label: '${_percent.round()}%',
                    onChanged: (v) => _changed(() => _percent = v),
                  ),
                ),
                SizedBox(width: 48, child: Text('${_percent.round()}%', textAlign: TextAlign.end)),
              ],
            ),
          ],
        );
      case ResizeMode.dimensions:
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _w,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Width (px)', border: OutlineInputBorder(), isDense: true),
                    onChanged: (_) => _changed(() {}),
                  ),
                ),
                IconButton(
                  tooltip: _keepAspect ? 'Aspect ratio locked' : 'Aspect ratio unlocked',
                  icon: Icon(_keepAspect ? Icons.link : Icons.link_off),
                  onPressed: () => _changed(() => _keepAspect = !_keepAspect),
                ),
                Expanded(
                  child: TextField(
                    controller: _h,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Height (px)', border: OutlineInputBorder(), isDense: true),
                    onChanged: (_) => _changed(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _keepAspect ? 'Fits inside this box, keeping proportions' : 'Stretches to exactly this size',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      case ResizeMode.fileSize:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _kb,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Maximum file size',
                suffixText: 'KB',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _changed(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final kb in const [50, 100, 200, 500, 1024])
                  ActionChip(
                    label: Text(kb >= 1024 ? '1 MB' : '$kb KB'),
                    onPressed: () => _changed(() => _kb.text = '$kb'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Great for online forms with upload limits. Output is JPG.', style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      case ResizeMode.preset:
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final p in _presets)
              ChoiceChip(
                label: Text(p.label),
                selected: _preset == p,
                onSelected: (_) => _changed(() => _preset = p),
              ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = _srcs.isEmpty ? null : _srcs.first;
    final preview = first == null || _mode == ResizeMode.fileSize ? null : _targetSize(first);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resize image'),
        actions: [IconButton(tooltip: 'Add images', icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _addMore)],
      ),
      body: _loading && _srcs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _srcs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final s = _srcs[i];
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(s.bytes, width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 192),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: Colors.black54,
                              padding: const EdgeInsets.all(2),
                              child: Text('${s.width}×${s.height}\n${formatBytes(s.bytes.length)}',
                                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 10)),
                            ),
                          ),
                          if (_srcs.length > 1)
                            Positioned(
                              top: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: () => _changed(() => _srcs.removeAt(i)),
                                child: const CircleAvatar(
                                  radius: 11,
                                  backgroundColor: Colors.black54,
                                  child: Icon(Icons.close, size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SectionTitle('Resize by'),
                SegmentedButton<ResizeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ResizeMode.percent, label: Text('%')),
                    ButtonSegment(value: ResizeMode.dimensions, label: Text('Size')),
                    ButtonSegment(value: ResizeMode.fileSize, label: Text('KB')),
                    ButtonSegment(value: ResizeMode.preset, label: Text('Presets')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => _changed(() => _mode = s.first),
                ),
                const SizedBox(height: 12),
                _modeOptions(),
                if (_mode == ResizeMode.dimensions || _mode == ResizeMode.preset)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Don't enlarge small images"),
                    value: _noEnlarge,
                    onChanged: (v) => _changed(() => _noEnlarge = v),
                  ),
                if (preview != null && first != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${first.width}×${first.height} → ${preview.$1}×${preview.$2} px',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                if (_mode != ResizeMode.fileSize) ...[
                  const SectionTitle('Format'),
                  SegmentedButton<OutFormat>(
                    segments: const [
                      ButtonSegment(value: OutFormat.same, label: Text('Keep')),
                      ButtonSegment(value: OutFormat.jpg, label: Text('JPG')),
                      ButtonSegment(value: OutFormat.png, label: Text('PNG')),
                    ],
                    selected: {_format},
                    onSelectionChanged: (s) => _changed(() => _format = s.first),
                  ),
                  if (_format != OutFormat.png) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('JPG quality'),
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
                        SizedBox(width: 44, child: Text('${_quality.round()}%', textAlign: TextAlign.end)),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: 16),
                if (_result == null)
                  FilledButton.icon(
                    onPressed: _srcs.isEmpty ? null : _run,
                    icon: const Icon(Icons.photo_size_select_large),
                    label: Text('Resize ${_srcs.length} image${_srcs.length == 1 ? '' : 's'}'),
                  )
                else ...[
                  for (final o in _result!)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(o.bytes, width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 96),
                      ),
                      title: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${o.src.width}×${o.src.height} → ${o.width}×${o.height} · '
                          '${formatBytes(o.src.bytes.length)} → ${formatBytes(o.bytes.length)}'),
                    ),
                  const SizedBox(height: 8),
                  if (_result!.length == 1)
                    ResultActions(
                      bytes: _result!.first.bytes,
                      fileName: _result!.first.name,
                      allowOpen: false,
                      mimeType: _mime(_result!.first.name),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => FileService.shareBytes(
                              [for (final o in _result!) (o.bytes, o.name)],
                              mimeType: 'image/*',
                            ),
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

/// JPEG from RGBA, flattening transparency onto white.
Uint8List _jpegFromRgba((Uint8List, int, int, int) a) {
  final (rgba, w, h, q) = a;
  for (var i = 0; i < rgba.length; i += 4) {
    final alpha = rgba[i + 3];
    if (alpha < 255) {
      final f = alpha / 255;
      rgba[i] = (rgba[i] * f + 255 * (1 - f)).round();
      rgba[i + 1] = (rgba[i + 1] * f + 255 * (1 - f)).round();
      rgba[i + 2] = (rgba[i + 2] * f + 255 * (1 - f)).round();
      rgba[i + 3] = 255;
    }
  }
  return JpegEncoder().compress(rgba, w, h, q);
}
