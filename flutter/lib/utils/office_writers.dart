import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Escapes text for XML and drops characters XML 1.0 forbids.
String xmlEscape(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x9 || r == 0xA || r == 0xD || (r >= 0x20 && r <= 0xD7FF) || (r >= 0xE000 && r <= 0xFFFD) || r >= 0x10000) {
      switch (r) {
        case 0x26:
          b.write('&amp;');
        case 0x3C:
          b.write('&lt;');
        case 0x3E:
          b.write('&gt;');
        case 0x22:
          b.write('&quot;');
        default:
          b.writeCharCode(r);
      }
    }
  }
  return b.toString();
}

void _add(Archive a, String name, String content) {
  final bytes = utf8.encode(content);
  a.addFile(ArchiveFile(name, bytes.length, bytes));
}

void _addBytes(Archive a, String name, Uint8List bytes) => a.addFile(ArchiveFile(name, bytes.length, bytes));

// =====================================================================================
// DOCX
// =====================================================================================

/// Minimal but valid Word (.docx) writer: headings, paragraphs, page breaks and images.
/// Complex-script fonts are set so Bengali/Hindi/Arabic text shows correctly in Word.
class DocxBuilder {
  DocxBuilder({this.latinFont = 'Calibri', this.complexFont = 'Nirmala UI', this.bodySizePt = 11});

  final String latinFont;
  final String complexFont;
  final double bodySizePt;

  final _body = StringBuffer();
  final _media = <(String, Uint8List)>[];
  int _imageId = 0;

  String _run(String text, {bool bold = false, bool italic = false, double? sizePt}) {
    final props = StringBuffer();
    if (bold) props.write('<w:b/><w:bCs/>');
    if (italic) props.write('<w:i/><w:iCs/>');
    if (sizePt != null) {
      final hp = (sizePt * 2).round();
      props.write('<w:sz w:val="$hp"/><w:szCs w:val="$hp"/>');
    }
    final rpr = props.isEmpty ? '' : '<w:rPr>$props</w:rPr>';
    // Keep explicit line breaks inside a paragraph.
    final parts = text.split('\n');
    final content = [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) '<w:br/>',
        '<w:t xml:space="preserve">${xmlEscape(parts[i])}</w:t>',
      ],
    ].join();
    return '<w:r>$rpr$content</w:r>';
  }

  void heading(String text, int level) {
    final style = level <= 1 ? 'Heading1' : 'Heading2';
    _body.write('<w:p><w:pPr><w:pStyle w:val="$style"/></w:pPr>${_run(text)}</w:p>');
  }

  void paragraph(String text, {bool bold = false, bool italic = false, double? sizePt, String align = 'left'}) {
    final jc = align == 'left' ? '' : '<w:jc w:val="$align"/>';
    _body.write('<w:p>${jc.isEmpty ? '' : '<w:pPr>$jc</w:pPr>'}${_run(text, bold: bold, italic: italic, sizePt: sizePt)}</w:p>');
  }

  void pageBreak() => _body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');

  /// Adds a JPEG/PNG image at [widthPt] × [heightPt].
  void image(Uint8List bytes, double widthPt, double heightPt, {String ext = 'jpeg'}) {
    final id = ++_imageId;
    final name = 'image$id.$ext';
    _media.add((name, bytes));
    final cx = (widthPt * 12700).round();
    final cy = (heightPt * 12700).round();
    _body.write('<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$id" name="Picture $id"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="$id" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rIdImg$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>');
  }

  /// Builds the .docx. Page size and margins are in points.
  Uint8List build({double pageWidthPt = 595, double pageHeightPt = 842, double marginPt = 54, String title = ''}) {
    final a = Archive();
    final hasJpeg = _media.any((m) => m.$1.endsWith('.jpeg'));
    final hasPng = _media.any((m) => m.$1.endsWith('.png'));
    _add(a, '[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '${hasJpeg ? '<Default Extension="jpeg" ContentType="image/jpeg"/>' : ''}'
        '${hasPng ? '<Default Extension="png" ContentType="image/png"/>' : ''}'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>');
    _add(a, '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>');
    final now = DateTime.now().toUtc().toIso8601String().split('.').first;
    _add(a, 'docProps/core.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${xmlEscape(title)}</dc:title><dc:creator>PDF Studio</dc:creator>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
        '</cp:coreProperties>');
    final rels = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>');
    for (var i = 0; i < _media.length; i++) {
      final (name, bytes) = _media[i];
      rels.write('<Relationship Id="rIdImg${i + 1}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
      _addBytes(a, 'word/media/$name', bytes);
    }
    rels.write('</Relationships>');
    _add(a, 'word/_rels/document.xml.rels', rels.toString());

    final body = (bodySizePt * 2).round();
    _add(a, 'word/styles.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:docDefaults><w:rPrDefault><w:rPr>'
        '<w:rFonts w:ascii="$latinFont" w:hAnsi="$latinFont" w:eastAsia="$latinFont" w:cs="$complexFont"/>'
        '<w:sz w:val="$body"/><w:szCs w:val="$body"/><w:lang w:val="en-US" w:bidi="bn-BD"/>'
        '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>'
        '<w:rPr><w:b/><w:bCs/><w:color w:val="1F3864"/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
        '<w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr>'
        '<w:rPr><w:b/><w:bCs/><w:color w:val="2F5496"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>'
        '</w:styles>');

    final tw = (pageWidthPt * 20).round();
    final th = (pageHeightPt * 20).round();
    final m = (marginPt * 20).round();
    final orient = pageWidthPt > pageHeightPt ? ' w:orient="landscape"' : '';
    _add(a, 'word/document.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<w:body>$_body'
        '<w:sectPr><w:pgSz w:w="$tw" w:h="$th"$orient/>'
        '<w:pgMar w:top="$m" w:right="$m" w:bottom="$m" w:left="$m" w:header="708" w:footer="708" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>');
    return ZipEncoder().encodeBytes(a);
  }
}

// =====================================================================================
// XLSX
// =====================================================================================

String columnName(int index) {
  var n = index + 1;
  final b = StringBuffer();
  while (n > 0) {
    final r = (n - 1) % 26;
    b.write(String.fromCharCode(65 + r));
    n = (n - 1) ~/ 26;
  }
  return b.toString().split('').reversed.join();
}

/// Minimal Excel (.xlsx) writer: several sheets, text and number cells, bold header row,
/// column widths fitted to content, frozen header.
class XlsxBuilder {
  final _sheets = <(String, List<List<Object?>>, bool)>[];

  void addSheet(String name, List<List<Object?>> rows, {bool headerRow = false}) {
    var n = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    if (n.isEmpty) n = 'Sheet${_sheets.length + 1}';
    if (n.length > 31) n = n.substring(0, 31);
    var unique = n;
    var k = 2;
    while (_sheets.any((s) => s.$1.toLowerCase() == unique.toLowerCase())) {
      final suffix = ' ($k)';
      unique = (n.length + suffix.length > 31 ? n.substring(0, 31 - suffix.length) : n) + suffix;
      k++;
    }
    _sheets.add((unique, rows, headerRow));
  }

  bool get isEmpty => _sheets.isEmpty;

  String _sheetXml(List<List<Object?>> rows, bool header) {
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final widths = List<double>.filled(cols, 8);
    for (final r in rows) {
      for (var c = 0; c < r.length; c++) {
        final v = r[c];
        final len = v == null ? 0 : v.toString().length;
        final w = (len * 1.1 + 2).clamp(8, 60).toDouble();
        if (w > widths[c]) widths[c] = w;
      }
    }
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">');
    if (header && rows.length > 1) {
      b.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
    }
    if (cols > 0) {
      b.write('<cols>');
      for (var c = 0; c < cols; c++) {
        b.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c].toStringAsFixed(1)}" customWidth="1"/>');
      }
      b.write('</cols>');
    }
    b.write('<sheetData>');
    for (var r = 0; r < rows.length; r++) {
      final style = header && r == 0 ? ' s="1"' : '';
      b.write('<row r="${r + 1}">');
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final v = row[c];
        if (v == null || (v is String && v.isEmpty)) continue;
        final ref = '${columnName(c)}${r + 1}';
        if (v is num && v.isFinite) {
          b.write('<c r="$ref"$style><v>$v</v></c>');
        } else {
          b.write('<c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${xmlEscape(v.toString())}</t></is></c>');
        }
      }
      b.write('</row>');
    }
    b.write('</sheetData></worksheet>');
    return b.toString();
  }

  Uint8List build() {
    if (_sheets.isEmpty) addSheet('Sheet1', const []);
    final a = Archive();
    final ct = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>');
    final wbRels = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>');
    final wb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>');
    for (var i = 0; i < _sheets.length; i++) {
      final (name, rows, header) = _sheets[i];
      final n = i + 1;
      ct.write('<Override PartName="/xl/worksheets/sheet$n.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
      wbRels.write('<Relationship Id="rId$n" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$n.xml"/>');
      wb.write('<sheet name="${xmlEscape(name)}" sheetId="$n" r:id="rId$n"/>');
      _add(a, 'xl/worksheets/sheet$n.xml', _sheetXml(rows, header));
    }
    ct.write('</Types>');
    wbRels.write('</Relationships>');
    wb.write('</sheets></workbook>');
    _add(a, '[Content_Types].xml', ct.toString());
    _add(a, '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>');
    _add(a, 'xl/workbook.xml', wb.toString());
    _add(a, 'xl/_rels/workbook.xml.rels', wbRels.toString());
    _add(a, 'xl/styles.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>');
    return ZipEncoder().encodeBytes(a);
  }
}
