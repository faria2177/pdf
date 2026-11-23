import 'dart:math' as math;
import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

/// A run of characters on one visual line, in page points (top-left origin, displayed orientation).
class TextLine {
  TextLine(this.text, this.bounds, this.charHeight);
  final String text;
  final Rect bounds;

  /// Median character height — a stand-in for the font size.
  final double charHeight;
}

class TextWord {
  TextWord(this.text, this.bounds);
  String text;
  Rect bounds;
}

/// A paragraph rebuilt from lines, with a heading level (0 = body, 1 = big heading, 2 = sub heading).
class TextParagraph {
  TextParagraph(this.text, this.level, this.charHeight);
  final String text;
  final int level;
  final double charHeight;
}

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == ' ';

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// Lines in reading order, as PDFium reports them (good for prose).
Future<List<TextLine>> readingLines(PdfPage page) async {
  final raw = await page.loadText();
  if (raw == null) return const [];
  final text = raw.fullText;
  final rects = raw.charRects;
  final lines = <TextLine>[];
  final buf = StringBuffer();
  Rect? box;
  final heights = <double>[];

  void flush() {
    final t = buf.toString().trimRight();
    if (t.trim().isNotEmpty && box != null) {
      lines.add(TextLine(t.trimLeft(), box!, _median(heights)));
    }
    buf.clear();
    box = null;
    heights.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\n' || c == '\r') {
      if (c == '\n' || (i + 1 < text.length && text[i + 1] != '\n')) flush();
      continue;
    }
    buf.write(c);
    if (!_isSpace(c) && i < rects.length) {
      final r = rects[i].toRect(page: page);
      if (r.width > 0 || r.height > 0) {
        box = box == null ? r : box!.expandToInclude(r);
        heights.add(r.height);
      }
    }
  }
  flush();
  return lines;
}

/// Joins lines into paragraphs and guesses headings from relative text size.
List<TextParagraph> paragraphsFromLines(List<TextLine> lines, {double? bodyHeight}) {
  if (lines.isEmpty) return const [];
  final body = bodyHeight ?? _median(lines.map((l) => l.charHeight).toList());
  int levelOf(TextLine l) {
    if (body <= 0) return 0;
    final ratio = l.charHeight / body;
    if (ratio >= 1.7) return 1;
    if (ratio >= 1.25) return 2;
    return 0;
  }

  final out = <TextParagraph>[];
  final buf = StringBuffer();
  var level = 0;
  var height = 0.0;
  TextLine? prev;

  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) out.add(TextParagraph(t, level, height));
    buf.clear();
  }

  for (final l in lines) {
    final lv = levelOf(l);
    var newPara = prev == null;
    if (prev != null) {
      final gap = l.bounds.top - prev.bounds.bottom;
      final lh = math.max(prev.charHeight, l.charHeight);
      if (lv != level) newPara = true;
      if (gap > lh * 0.9) newPara = true; // blank space between lines
      if (gap < -lh * 2) newPara = true; // jumped back up: new column
      if ((l.bounds.left - prev.bounds.left) > lh * 1.5 && level == 0) newPara = true; // indent
      final prevText = buf.toString().trimRight();
      if (prevText.endsWith(':') || RegExp(r'^\s*([•\-–*▪●]|\d+[.)])\s').hasMatch(l.text)) newPara = true;
    }
    if (newPara) {
      flush();
      level = lv;
      height = l.charHeight;
      buf.write(l.text);
    } else {
      final cur = buf.toString();
      if (cur.endsWith('-') && !cur.endsWith(' -')) {
        // hyphenated word split across lines
        buf
          ..clear()
          ..write(cur.substring(0, cur.length - 1))
          ..write(l.text);
      } else {
        buf.write(' ');
        buf.write(l.text);
      }
    }
    prev = l;
  }
  flush();
  return out;
}

/// Words with positions (for table detection).
Future<List<TextWord>> pageWords(PdfPage page) async {
  final raw = await page.loadText();
  if (raw == null) return const [];
  final text = raw.fullText;
  final rects = raw.charRects;
  final words = <TextWord>[];
  final buf = StringBuffer();
  Rect? box;

  void flush() {
    if (buf.isNotEmpty && box != null) words.add(TextWord(buf.toString(), box!));
    buf.clear();
    box = null;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (_isSpace(c) || i >= rects.length) {
      flush();
      continue;
    }
    final r = rects[i].toRect(page: page);
    if (r.width <= 0 && r.height <= 0) {
      flush();
      continue;
    }
    if (box != null) {
      final sameLine = (r.center.dy - box!.center.dy).abs() < math.max(r.height, box!.height) * 0.6;
      final gap = r.left - box!.right;
      if (!sameLine || gap > r.height * 0.45 || gap < -r.height * 2) flush();
    }
    buf.write(c);
    box = box == null ? r : box!.expandToInclude(r);
  }
  flush();
  return words;
}

/// Rebuilds a table (rows × columns of strings) from word positions.
/// Rows = words sharing a baseline; cells = runs of words split by wide gaps;
/// columns = cell left edges clustered across the whole page.
List<List<String>> tableFromWords(List<TextWord> words, {double columnTolerance = 10}) {
  if (words.isEmpty) return const [];
  final sorted = [...words]..sort((a, b) => a.bounds.center.dy.compareTo(b.bounds.center.dy));

  // 1. rows
  final rows = <List<TextWord>>[];
  for (final w in sorted) {
    if (rows.isNotEmpty) {
      final row = rows.last;
      final cy = row.map((e) => e.bounds.center.dy).reduce((a, b) => a + b) / row.length;
      final h = row.map((e) => e.bounds.height).reduce(math.max);
      if ((w.bounds.center.dy - cy).abs() < math.min(h, w.bounds.height) * 0.55) {
        row.add(w);
        continue;
      }
    }
    rows.add([w]);
  }

  // 2. cells inside each row
  final rowCells = <List<TextWord>>[];
  for (final row in rows) {
    row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    final cells = <TextWord>[];
    for (final w in row) {
      if (cells.isNotEmpty) {
        final last = cells.last;
        final gap = w.bounds.left - last.bounds.right;
        final space = math.max(last.bounds.height, w.bounds.height) * 0.9;
        if (gap < space) {
          last.text = '${last.text} ${w.text}';
          last.bounds = last.bounds.expandToInclude(w.bounds);
          continue;
        }
      }
      cells.add(TextWord(w.text, w.bounds));
    }
    rowCells.add(cells);
  }

  // 3. columns from clustered left edges
  final lefts = [for (final r in rowCells) for (final c in r) c.bounds.left]..sort();
  final anchors = <double>[];
  final counts = <int>[];
  for (final x in lefts) {
    if (anchors.isNotEmpty && x - anchors.last <= columnTolerance) {
      final n = counts.last;
      anchors[anchors.length - 1] = (anchors.last * n + x) / (n + 1);
      counts[counts.length - 1] = n + 1;
    } else {
      anchors.add(x);
      counts.add(1);
    }
  }
  int columnOf(double x) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < anchors.length; i++) {
      final d = (anchors[i] - x).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  final table = <List<String>>[];
  for (final cells in rowCells) {
    final row = List<String>.filled(anchors.length, '');
    for (final c in cells) {
      final col = columnOf(c.bounds.left);
      row[col] = row[col].isEmpty ? c.text : '${row[col]} ${c.text}';
    }
    table.add(row);
  }

  // Drop columns that are empty everywhere.
  final keep = [
    for (var i = 0; i < anchors.length; i++)
      if (table.any((r) => r[i].trim().isNotEmpty)) i,
  ];
  return [for (final r in table) [for (final i in keep) r[i]]];
}

/// "1,234.50" -> 1234.5, "12%" -> 0.12, otherwise null.
num? parseNumberCell(String s) {
  var t = s.trim();
  if (t.isEmpty || t.length > 24) return null;
  var percent = false;
  if (t.endsWith('%')) {
    percent = true;
    t = t.substring(0, t.length - 1).trim();
  }
  var negative = false;
  if (t.startsWith('(') && t.endsWith(')')) {
    negative = true;
    t = t.substring(1, t.length - 1);
  }
  t = t.replaceAll(RegExp(r'^[৳$€£¥₹]\s*'), '');
  if (!RegExp(r'^[-+]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$').hasMatch(t)) return null;
  var v = num.tryParse(t.replaceAll(',', ''));
  if (v == null) return null;
  if (negative) v = -v;
  if (percent) v = v / 100;
  return v;
}
