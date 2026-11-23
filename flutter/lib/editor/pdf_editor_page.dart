import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../pages/tools/tool_base.dart';
import '../services/file_service.dart';
import '../services/pdf_open.dart';
import '../services/pdfbox_service.dart';
import '../widgets/dialogs.dart';
import '../widgets/result_actions.dart';
import '../widgets/tool_widgets.dart';
import 'edit_items.dart';
import 'signature_creator_page.dart';
import 'signature_store.dart';

enum EditorMode { edit, sign }

enum EditTool {
  select('Select', Icons.near_me_outlined),
  hand('Zoom', Icons.pan_tool_outlined),
  text('Text', Icons.text_fields),
  pen('Draw', Icons.gesture),
  highlighter('Highlight', Icons.border_color_outlined),
  rect('Box', Icons.crop_square),
  ellipse('Circle', Icons.circle_outlined),
  line('Line', Icons.horizontal_rule),
  arrow('Arrow', Icons.arrow_right_alt),
  whiteout('Whiteout', Icons.format_color_reset_outlined),
  image('Image', Icons.add_photo_alternate_outlined),
  signature('Signature', Icons.draw_outlined),
  initials('Initials', Icons.short_text),
  date('Date', Icons.today_outlined),
  check('Check', Icons.check),
  cross('Cross', Icons.close);

  const EditTool(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _palette = [
  Color(0xFF111111),
  Color(0xFF1565C0),
  Color(0xFFD32F2F),
  Color(0xFF2E7D32),
  Color(0xFFF9A825),
  Color(0xFF6A1B9A),
  Color(0xFFFFFFFF),
];
const _highlightPalette = [Color(0xFFFFEB3B), Color(0xFF76FF03), Color(0xFF40C4FF), Color(0xFFFF80AB), Color(0xFFFFAB40)];

enum _Drag { none, move, resize, draw }

/// "Edit PDF" and "Sign PDF": annotate pages with text, drawings, shapes, images and
/// signatures. Edits are flattened onto the pages as a transparent overlay; the original
/// content stays vector and selectable.
class PdfEditorPage extends StatefulWidget {
  const PdfEditorPage({required this.path, required this.name, this.mode = EditorMode.edit, super.key});
  final String path;
  final String name;
  final EditorMode mode;

  @override
  State<PdfEditorPage> createState() => _PdfEditorPageState();
}

class _PdfEditorPageState extends PdfToolState<PdfEditorPage> {
  @override
  String get path => widget.path;
  @override
  String get name => widget.name;

  bool get _sign => widget.mode == EditorMode.sign;

  int _page = 0;
  Map<int, List<EditItem>> _items = {};
  final _undo = <Map<int, List<EditItem>>>[];
  final _redo = <Map<int, List<EditItem>>>[];
  int _nextId = 1;
  int? _selected;
  late EditTool _tool = _sign ? EditTool.signature : EditTool.select;

  Color _color = _palette.first;
  Color _highlight = _highlightPalette.first;
  double _stroke = 0.003; // fraction of page height
  double _fontSize = 0.022; // fraction of page height
  bool _bold = false;
  bool _italic = false;

  final _transform = TransformationController();
  Size _view = Size.zero; // page size on screen
  EditItem? _preview;
  _Drag _drag = _Drag.none;
  Offset _dragStart = Offset.zero;
  EditItem? _dragOrig;
  bool _saved = true;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  List<EditItem> get _pageItems => _items[_page] ?? const [];
  EditItem? get _selectedItem => _pageItems.where((i) => i.id == _selected).firstOrNull;
  PdfPage get _pdfPage => doc!.pages[_page];
  double get _aspect => _pdfPage.width / _pdfPage.height; // width / height

  // ------------------------------------------------------------------ state changes

  void _commit(List<EditItem> list, {int? page}) {
    final pg = page ?? _page;
    setState(() {
      _undo.add(Map.of(_items));
      if (_undo.length > 80) _undo.removeAt(0);
      _redo.clear();
      _items = {..._items, pg: list};
      _saved = false;
    });
  }

  void _replace(EditItem item) => _commit([for (final i in _pageItems) i.id == item.id ? item : i]);

  void _add(EditItem item) {
    _commit([..._pageItems, item]);
    setState(() => _selected = item.id);
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_items);
      _items = _undo.removeLast();
      _selected = null;
    });
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_items);
      _items = _redo.removeLast();
      _selected = null;
    });
  }

  void _deleteSelected() {
    if (_selected == null) return;
    _commit(_pageItems.where((i) => i.id != _selected).toList());
    setState(() => _selected = null);
  }

  void _duplicateSelected() {
    final s = _selectedItem;
    if (s == null) return;
    final copy = switch (s) {
      TextItem() => TextItem(
          id: _nextId++,
          text: s.text,
          rect: s.rect,
          fontSize: s.fontSize,
          color: s.color,
          bold: s.bold,
          italic: s.italic,
          underline: s.underline,
          background: s.background,
          align: s.align,
          fontFamily: s.fontFamily),
      InkItem() => InkItem(id: _nextId++, points: s.points, color: s.color, width: s.width, highlighter: s.highlighter),
      ShapeItem() => ShapeItem(id: _nextId++, kind: s.kind, a: s.a, b: s.b, stroke: s.stroke, width: s.width, fill: s.fill),
      ImageItem() => ImageItem(id: _nextId++, image: s.image, bytes: s.bytes, rect: s.rect, opacity: s.opacity),
    };
    _add(copy.moved(const Offset(0.03, 0.03)));
  }

  void _bringToFront() {
    final s = _selectedItem;
    if (s == null) return;
    _commit([..._pageItems.where((i) => i.id != s.id), s]);
  }

  void _applyColor(Color c) {
    setState(() {
      if (_tool == EditTool.highlighter) {
        _highlight = c;
      } else {
        _color = c;
      }
    });
    final s = _selectedItem;
    if (s == null) return;
    switch (s) {
      case TextItem():
        _replace(s.copyWith(color: c));
      case InkItem():
        _replace(s.copyWith(color: c));
      case ShapeItem():
        _replace(s.kind == ShapeKind.whiteout ? s.copyWith(fill: c) : s.copyWith(stroke: c));
      case ImageItem():
        break;
    }
  }

  // ------------------------------------------------------------------ geometry

  Offset _norm(Offset local) => Offset(
        (local.dx / _view.width).clamp(0.0, 1.0),
        (local.dy / _view.height).clamp(0.0, 1.0),
      );

  Rect _px(Rect r) => Rect.fromLTRB(r.left * _view.width, r.top * _view.height, r.right * _view.width, r.bottom * _view.height);

  bool _onHandle(Offset local) {
    final s = _selectedItem;
    if (s == null) return false;
    final corner = _px(s.bounds).inflate(6).bottomRight;
    return (corner - local).distance < 26;
  }

  EditItem? _hit(Offset local) {
    for (final i in _pageItems.reversed) {
      if (_px(i.bounds).inflate(14).contains(local)) return i;
    }
    return null;
  }

  /// Rect centered at [c] with [w] as a fraction of page width and the image's aspect.
  Rect _placeRect(Offset c, double w, double imgAspect) {
    final h = w / imgAspect * _aspect; // in page-height units
    var left = c.dx - w / 2, top = c.dy - h / 2;
    left = left.clamp(0.0, math.max(0.0, 1 - w));
    top = top.clamp(0.0, math.max(0.0, 1 - h));
    return Rect.fromLTWH(left, top, w, h);
  }

  Rect _squareAt(Offset c, double hFrac) {
    final w = hFrac / _aspect;
    return Rect.fromCenter(center: c, width: w, height: hFrac);
  }

  // ------------------------------------------------------------------ gestures

  Future<void> _onTap(Offset local) async {
    final n = _norm(local);
    switch (_tool) {
      case EditTool.select:
        final hit = _hit(local);
        setState(() => _selected = hit?.id);
      case EditTool.text:
        await _newText(n);
      case EditTool.date:
        final d = DateTime.now();
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        final text = '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
        final item = TextItem(
          id: _nextId++,
          text: text,
          rect: Rect.fromLTWH(n.dx, n.dy, 0.3, 0.03),
          fontSize: _fontSize,
          color: _color,
        ).fitted(_view);
        _add(item);
        setState(() => _tool = EditTool.select);
      case EditTool.check:
      case EditTool.cross:
        final r = _squareAt(n, 0.028);
        _add(ShapeItem(
          id: _nextId++,
          kind: _tool == EditTool.check ? ShapeKind.check : ShapeKind.cross,
          a: r.topLeft,
          b: r.bottomRight,
          stroke: _color,
          width: _stroke,
        ));
      case EditTool.image:
        await _placeImage(n);
      case EditTool.signature:
      case EditTool.initials:
        await _placeSignature(n, _tool == EditTool.initials ? SignatureKind.initials : SignatureKind.signature);
      default:
        break;
    }
  }

  void _onPanStart(DragStartDetails d) {
    final local = d.localPosition;
    final n = _norm(local);
    _dragStart = n;
    switch (_tool) {
      case EditTool.select:
        if (_onHandle(local)) {
          _drag = _Drag.resize;
          _dragOrig = _selectedItem;
        } else {
          final hit = _hit(local);
          if (hit != null) {
            setState(() => _selected = hit.id);
            _drag = _Drag.move;
            _dragOrig = hit;
          } else {
            _drag = _Drag.none;
            setState(() => _selected = null);
          }
        }
      case EditTool.pen:
      case EditTool.highlighter:
        _drag = _Drag.draw;
        setState(() => _preview = InkItem(
              id: _nextId++,
              points: [n],
              color: _tool == EditTool.highlighter ? _highlight : _color,
              width: _tool == EditTool.highlighter ? math.max(_stroke * 5, 0.016) : _stroke,
              highlighter: _tool == EditTool.highlighter,
            ));
      case EditTool.rect:
      case EditTool.ellipse:
      case EditTool.line:
      case EditTool.arrow:
      case EditTool.whiteout:
        _drag = _Drag.draw;
        setState(() => _preview = ShapeItem(
              id: _nextId++,
              kind: switch (_tool) {
                EditTool.rect => ShapeKind.rect,
                EditTool.ellipse => ShapeKind.ellipse,
                EditTool.line => ShapeKind.line,
                EditTool.arrow => ShapeKind.arrow,
                _ => ShapeKind.whiteout,
              },
              a: n,
              b: n,
              stroke: _color,
              width: _stroke,
              fill: _tool == EditTool.whiteout ? Colors.white : null,
            ));
      default:
        _drag = _Drag.none;
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final n = _norm(d.localPosition);
    switch (_drag) {
      case _Drag.move:
        final o = _dragOrig;
        if (o == null) return;
        final moved = o.moved(n - _dragStart);
        setState(() => _items = {..._items, _page: [for (final i in _pageItems) i.id == o.id ? moved : i]});
      case _Drag.resize:
        final o = _dragOrig;
        if (o == null) return;
        final b = o.bounds;
        var r = Rect.fromLTRB(b.left, b.top, math.max(b.left + 0.01, n.dx), math.max(b.top + 0.01, n.dy));
        if (o is ImageItem || o is TextItem) {
          // keep proportions
          final s = r.width / math.max(b.width, 1e-6);
          r = Rect.fromLTWH(b.left, b.top, b.width * s, b.height * s);
        }
        var resized = o.resized(r);
        if (resized is TextItem) resized = resized.fitted(_view);
        setState(() => _items = {..._items, _page: [for (final i in _pageItems) i.id == o.id ? resized : i]});
      case _Drag.draw:
        final pv = _preview;
        if (pv is InkItem) {
          setState(() => _preview = pv.copyWith(points: [...pv.points, n]));
        } else if (pv is ShapeItem) {
          var end = n;
          if (pv.kind == ShapeKind.line || pv.kind == ShapeKind.arrow) {
            // snap to horizontal/vertical when close
            final dx = (end.dx - pv.a.dx) * _view.width, dy = (end.dy - pv.a.dy) * _view.height;
            if (dy.abs() < 10) end = Offset(end.dx, pv.a.dy);
            if (dx.abs() < 10) end = Offset(pv.a.dx, end.dy);
          }
          setState(() => _preview = pv.copyWith(b: end));
        }
      case _Drag.none:
        break;
    }
  }

  void _onPanEnd(DragEndDetails _) {
    switch (_drag) {
      case _Drag.move:
      case _Drag.resize:
        final o = _dragOrig;
        if (o != null) {
          final now = _pageItems.where((i) => i.id == o.id).firstOrNull;
          if (now != null && now != o) {
            // record the gesture as one undo step
            final current = _pageItems;
            setState(() => _items = {..._items, _page: [for (final i in current) i.id == o.id ? o : i]});
            _commit(current);
          }
        }
      case _Drag.draw:
        final pv = _preview;
        setState(() => _preview = null);
        if (pv != null) {
          final b = _px(pv.bounds);
          final tiny = pv is ShapeItem && b.width < 6 && b.height < 6;
          if (!tiny) {
            _commit([..._pageItems, pv]);
            if (pv is ShapeItem) setState(() => _selected = pv.id);
          }
        }
      case _Drag.none:
        break;
    }
    _drag = _Drag.none;
    _dragOrig = null;
  }

  // ------------------------------------------------------------------ creators

  Future<void> _newText(Offset at, {TextItem? editing}) async {
    final r = await showDialog<(String, bool, bool, Color, Color?)>(
      context: context,
      builder: (_) => _TextDialog(
        initial: editing?.text ?? '',
        bold: editing?.bold ?? _bold,
        italic: editing?.italic ?? _italic,
        color: editing?.color ?? _color,
        background: editing?.background,
      ),
    );
    if (r == null || r.$1.trim().isEmpty) return;
    final (text, bold, italic, color, bg) = r;
    setState(() {
      _bold = bold;
      _italic = italic;
      _color = color;
    });
    if (editing != null) {
      _replace(editing
          .copyWith(text: text, bold: bold, italic: italic, color: color, background: bg, clearBackground: bg == null)
          .fitted(_view));
      return;
    }
    // Width: up to the right edge, at most 60% of the page.
    final w = math.min(0.6, math.max(0.15, 0.98 - at.dx));
    final item = TextItem(
      id: _nextId++,
      text: text,
      rect: Rect.fromLTWH(math.min(at.dx, 1 - w), at.dy, w, _fontSize),
      fontSize: _fontSize,
      color: color,
      bold: bold,
      italic: italic,
      background: bg,
    ).fitted(_view);
    _add(item);
    setState(() => _tool = EditTool.select);
  }

  Future<(ui.Image, Uint8List)?> _decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final f = await codec.getNextFrame();
      codec.dispose();
      return (f.image, bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _placeImage(Offset at) async {
    final files = await FileService.pickImages();
    if (files.isEmpty) return;
    final bytes = await File(files.first.path).readAsBytes();
    final img = await _decode(bytes);
    if (img == null) {
      if (mounted) toast(context, 'Unsupported image');
      return;
    }
    final (image, data) = img;
    _add(ImageItem(id: _nextId++, image: image, bytes: data, rect: _placeRect(at, 0.4, image.width / image.height)));
    setState(() => _tool = EditTool.select);
  }

  Future<void> _placeSignature(Offset at, SignatureKind kind) async {
    final file = await _pickSignature(kind);
    if (file == null) return;
    final img = await _decode(await file.readAsBytes());
    if (img == null) return;
    final (image, data) = img;
    final w = kind == SignatureKind.initials ? 0.12 : 0.3;
    _add(ImageItem(id: _nextId++, image: image, bytes: data, rect: _placeRect(at, w, image.width / image.height)));
    setState(() => _tool = EditTool.select);
    if (mounted) toast(context, 'Drag to move · corner handle to resize');
  }

  Future<File?> _pickSignature(SignatureKind kind) async {
    var saved = (await SignatureStore.list()).where((s) => s.kind == kind).toList();
    if (!mounted) return null;
    if (saved.isEmpty) {
      return Navigator.of(context).push<File>(MaterialPageRoute(builder: (_) => SignatureCreatorPage(kind: kind)));
    }
    return showModalBottomSheet<File>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(kind == SignatureKind.initials ? 'Your initials' : 'Your signatures',
                    style: Theme.of(sheet).textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text('Tap to place · long-press to delete', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final s in saved)
                      GestureDetector(
                        onTap: () => Navigator.pop(sheet, s.file),
                        onLongPress: () async {
                          if (await confirm(sheet, 'Delete this ${kind.name}?', ok: 'Delete')) {
                            await SignatureStore.delete(s);
                            saved = saved.where((x) => x != s).toList();
                            setSheet(() {});
                          }
                        },
                        child: Container(
                          width: 150,
                          height: 70,
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Theme.of(sheet).colorScheme.outlineVariant),
                          ),
                          child: Image.file(s.file, fit: BoxFit.contain),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final f = await Navigator.of(sheet)
                        .push<File>(MaterialPageRoute(builder: (_) => SignatureCreatorPage(kind: kind)));
                    if (f != null && sheet.mounted) Navigator.pop(sheet, f);
                  },
                  icon: const Icon(Icons.add),
                  label: Text(kind == SignatureKind.initials ? 'New initials' : 'New signature'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ save

  Future<void> _save() async {
    final pages = _items.entries.where((e) => e.value.isNotEmpty).toList();
    if (pages.isEmpty) {
      toast(context, _sign ? 'Place your signature first' : 'Nothing to save yet');
      return;
    }
    setState(() => _selected = null);
    final bytes = await runWithProgress(context, 'Saving PDF', (update) async {
      final tmp = await getTemporaryDirectory();
      final stamps = <int, String>{};
      for (var i = 0; i < pages.length; i++) {
        final idx = pages[i].key;
        update('Page ${idx + 1}', (i + 1) / pages.length * 0.7);
        final page = doc!.pages[idx];
        var scale = 200 / 72;
        final longest = math.max(page.width, page.height) * scale;
        if (longest > 3200) scale *= 3200 / longest;
        final w = (page.width * scale).round(), h = (page.height * scale).round();
        final png = await renderItemsPng(pages[i].value, w, h);
        final f = File(p.join(tmp.path, 'overlay_${DateTime.now().microsecondsSinceEpoch}_$idx.png'));
        await f.writeAsBytes(png, flush: true);
        stamps[idx] = f.path;
      }
      update('Writing PDF…', null);
      try {
        return await PdfBoxService.stamp(input: widget.path, stamps: stamps, password: knownPassword(widget.path));
      } finally {
        for (final s in stamps.values) {
          try {
            File(s).deleteSync();
          } catch (_) {}
        }
      }
    });
    if (bytes == null || !mounted) return;
    setState(() => _saved = true);
    final outName = '${FileService.withoutExtension(widget.name)}_${_sign ? 'signed' : 'edited'}.pdf';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: Text(outName),
                subtitle: Text('${pages.length} page(s) changed · ${formatBytes(bytes.length)}'),
              ),
              if (_sign)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('This is a visual (electronic) signature, not a certificate-based digital signature.',
                      style: TextStyle(fontSize: 12)),
                ),
              ResultActions(bytes: bytes, fileName: outName),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ UI pieces

  List<EditTool> get _tools => _sign
      ? const [EditTool.signature, EditTool.initials, EditTool.text, EditTool.date, EditTool.check, EditTool.cross, EditTool.select, EditTool.hand]
      : const [
          EditTool.select,
          EditTool.text,
          EditTool.pen,
          EditTool.highlighter,
          EditTool.rect,
          EditTool.ellipse,
          EditTool.line,
          EditTool.arrow,
          EditTool.whiteout,
          EditTool.image,
          EditTool.signature,
          EditTool.date,
          EditTool.check,
          EditTool.hand,
        ];

  String get _hint => switch (_tool) {
        EditTool.select => 'Tap an item to select · drag to move · corner to resize',
        EditTool.hand => 'Pinch to zoom, drag to pan',
        EditTool.text => 'Tap where the text should go',
        EditTool.pen => 'Draw with your finger',
        EditTool.highlighter => 'Drag over text to highlight',
        EditTool.whiteout => 'Drag to cover content with white',
        EditTool.image => 'Tap where to place the image',
        EditTool.signature => 'Tap where you want to sign',
        EditTool.initials => 'Tap where your initials go',
        EditTool.date => "Tap to stamp today's date",
        EditTool.check || EditTool.cross => 'Tap to place',
        _ => 'Drag to draw',
      };

  Widget _colorBar() {
    final colors = _tool == EditTool.highlighter ? _highlightPalette : _palette;
    final current = _tool == EditTool.highlighter ? _highlight : _color;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final c in colors)
            GestureDetector(
              onTap: () => _applyColor(c),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                width: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == current ? Theme.of(context).colorScheme.primary : Colors.black26,
                    width: c == current ? 3 : 1,
                  ),
                ),
              ),
            ),
          const VerticalDivider(),
          if (_tool == EditTool.text || _selectedItem is TextItem) ...[
            IconButton(
              tooltip: 'Smaller text',
              icon: const Icon(Icons.text_decrease),
              onPressed: () => _scaleFont(1 / 1.15),
            ),
            IconButton(
              tooltip: 'Larger text',
              icon: const Icon(Icons.text_increase),
              onPressed: () => _scaleFont(1.15),
            ),
          ] else ...[
            IconButton(tooltip: 'Thinner', icon: const Icon(Icons.remove), onPressed: () => _scaleStroke(1 / 1.3)),
            Center(child: Container(width: 22, height: math.max(1.5, _stroke * 900), color: _color)),
            IconButton(tooltip: 'Thicker', icon: const Icon(Icons.add), onPressed: () => _scaleStroke(1.3)),
          ],
        ],
      ),
    );
  }

  void _scaleFont(double f) {
    setState(() => _fontSize = (_fontSize * f).clamp(0.008, 0.12));
    final s = _selectedItem;
    if (s is TextItem) _replace(s.copyWith(fontSize: (s.fontSize * f).clamp(0.008, 0.12)).fitted(_view));
  }

  void _scaleStroke(double f) {
    setState(() => _stroke = (_stroke * f).clamp(0.0008, 0.02));
    final s = _selectedItem;
    if (s is InkItem) _replace(s.copyWith(width: (s.width * f).clamp(0.0008, 0.06)));
    if (s is ShapeItem) _replace(s.copyWith(width: (s.width * f).clamp(0.0008, 0.02)));
  }

  Widget _selectionBar() {
    final s = _selectedItem;
    if (s == null) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            if (s is TextItem)
              TextButton.icon(
                onPressed: () => _newText(Offset.zero, editing: s),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Edit text'),
              ),
            if (s is ImageItem)
              TextButton.icon(
                onPressed: () => _replace(s.copyWith(opacity: s.opacity > 0.6 ? 0.5 : 1)),
                icon: const Icon(Icons.opacity, size: 18),
                label: Text(s.opacity > 0.6 ? 'Fade' : 'Solid'),
              ),
            if (s is ShapeItem && (s.kind == ShapeKind.rect || s.kind == ShapeKind.ellipse))
              TextButton.icon(
                onPressed: () => _replace(s.fill == null ? s.copyWith(fill: s.stroke.withValues(alpha: 0.25)) : s.copyWith(clearFill: true)),
                icon: const Icon(Icons.format_color_fill, size: 18),
                label: Text(s.fill == null ? 'Fill' : 'No fill'),
              ),
            TextButton.icon(onPressed: _duplicateSelected, icon: const Icon(Icons.copy, size: 18), label: const Text('Duplicate')),
            TextButton.icon(onPressed: _bringToFront, icon: const Icon(Icons.flip_to_front, size: 18), label: const Text('Front')),
            TextButton.icon(
              onPressed: _deleteSelected,
              icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).colorScheme.error),
              label: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageCanvas() {
    return LayoutBuilder(builder: (context, c) {
      var w = c.maxWidth - 16;
      var h = w / _aspect;
      if (h > c.maxHeight - 16) {
        h = c.maxHeight - 16;
        w = h * _aspect;
      }
      if (_view != Size(w, h)) {
        // Keep text boxes fitted when the screen size changes.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
      _view = Size(w, h);
      final hand = _tool == EditTool.hand;
      return InteractiveViewer(
        transformationController: _transform,
        panEnabled: hand,
        scaleEnabled: hand,
        maxScale: 5,
        boundaryMargin: const EdgeInsets.all(80),
        child: Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
                    ),
                    child: PdfPageView(key: ValueKey('ed_$_page'), document: doc, pageNumber: _page + 1, maximumDpi: 220),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: hand,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => _onTap(d.localPosition),
                      onPanStart: _onPanStart,
                      onPanUpdate: _onPanUpdate,
                      onPanEnd: _onPanEnd,
                      child: CustomPaint(
                        painter: ItemsPainter(
                          _pageItems,
                          selectedId: _selected,
                          preview: _preview,
                          selectionColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final changedPages = _items.values.where((l) => l.isNotEmpty).length;
    return PopScope(
      canPop: _saved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirm(context, 'Your changes have not been saved.', ok: 'Discard', title: 'Leave?') && context.mounted) {
          setState(() => _saved = true);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_sign ? 'Sign PDF' : 'Edit PDF'),
          actions: [
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo.isEmpty ? null : _undoAction),
            IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: _redo.isEmpty ? null : _redoAction),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: doc == null ? null : _save, child: const Text('Save')),
            ),
          ],
        ),
        body: doc == null
            ? loading()
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(_hint, style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Expanded(child: Container(color: scheme.surfaceContainerLow, child: _pageCanvas())),
                  _selectionBar(),
                  Material(
                    color: scheme.surfaceContainer,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.chevron_left),
                                onPressed: _page > 0
                                    ? () => setState(() {
                                          _page--;
                                          _selected = null;
                                          _transform.value = Matrix4.identity();
                                        })
                                    : null,
                              ),
                              Expanded(
                                child: Text(
                                  'Page ${_page + 1} of $pageCount'
                                  '${changedPages > 0 ? '  ·  $changedPages edited' : ''}',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.chevron_right),
                                onPressed: _page < pageCount - 1
                                    ? () => setState(() {
                                          _page++;
                                          _selected = null;
                                          _transform.value = Matrix4.identity();
                                        })
                                    : null,
                              ),
                            ],
                          ),
                          if (_tool != EditTool.hand && _tool != EditTool.image && _tool != EditTool.signature && _tool != EditTool.initials)
                            _colorBar(),
                          SizedBox(
                            height: 64,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              children: [
                                for (final t in _tools)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: () => setState(() {
                                      _tool = t;
                                      if (t != EditTool.select) _selected = null;
                                    }),
                                    child: Container(
                                      width: 64,
                                      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: t == _tool ? scheme.primaryContainer : null,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(t.icon, color: t == _tool ? scheme.primary : null),
                                          const SizedBox(height: 2),
                                          Text(t.label, style: const TextStyle(fontSize: 11), maxLines: 1),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.initial, required this.bold, required this.italic, required this.color, this.background});
  final String initial;
  final bool bold;
  final bool italic;
  final Color color;
  final Color? background;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);
  late bool _bold = widget.bold;
  late bool _italic = widget.italic;
  late Color _color = widget.color;
  late Color? _bg = widget.background;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial.isEmpty ? 'Add text' : 'Edit text'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 5,
              style: TextStyle(
                fontWeight: _bold ? FontWeight.bold : null,
                fontStyle: _italic ? FontStyle.italic : null,
                color: _color == Colors.white ? Colors.black : _color,
              ),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Type here'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton.filledTonal(
                  isSelected: _bold,
                  icon: const Icon(Icons.format_bold),
                  onPressed: () => setState(() => _bold = !_bold),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  isSelected: _italic,
                  icon: const Icon(Icons.format_italic),
                  onPressed: () => setState(() => _italic = !_italic),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  isSelected: _bg != null,
                  tooltip: 'White background',
                  icon: const Icon(Icons.format_color_fill),
                  onPressed: () => setState(() => _bg = _bg == null ? Colors.white : null),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: c == _color ? Theme.of(context).colorScheme.primary : Colors.black26, width: c == _color ? 3 : 1),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_ctrl.text, _bold, _italic, _color, _bg)),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
