import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/paper_document.dart';

/// Lays out a [PaperDocument] on A4 pages and packs them into a PDF.
///
/// Text is measured and drawn with Flutter's own text engine, so Bengali
/// conjuncts and vowel signs are shaped correctly. Each page is rendered as
/// an image and embedded in the PDF (the same approach as the question
/// paper export).
abstract final class PaperDocumentRender {
  static const double _dpi = 150;
  static const double _pageW = 1240; // A4 at 150 dpi
  static const double _pageH = 1754;
  static const double _marginX = 130;
  static const double _marginTop = 130;
  static const double _marginBottom = 140;
  static const double _contentW = _pageW - _marginX * 2;
  static const double _gutter = 56;
  static const String _family = 'Noto Serif Bengali';
  static const List<String> _fallback = ['Hind Siliguri', 'DejaVu Sans'];
  static const Color _ink = Color(0xFF111111);
  static const Color _muted = Color(0xFF666666);

  static double _pt(double pt) => pt * _dpi / 72;

  /// Builds the PDF bytes for [doc].
  static Future<Uint8List> build(PaperDocument doc) async {
    final lines = _layoutLines(doc);
    final pages = _paginate(lines);
    final pdf = pw.Document(title: doc.title);
    for (var i = 0; i < pages.length; i++) {
      final png = await _renderPage(doc, pages[i], i + 1, pages.length);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            pw.MemoryImage(png),
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    return pdf.save();
  }

  // ── Layout ─────────────────────────────────────────────────────

  static List<_Line> _layoutLines(PaperDocument doc) {
    final out = <_Line>[];
    final h = doc.header;
    if (!h.isEmpty) {
      void centred(
        String text,
        double pt, {
        bool bold = false,
        double after = 4,
      }) {
        if (text.trim().isEmpty) return;
        out.add(
          _make(
            span: TextSpan(text: text.trim(), style: _plain(pt, bold: bold)),
            align: TextAlign.center,
            after: _pt(after),
          ),
        );
      }

      centred(h.school, 17, bold: true);
      centred(h.exam, 14, bold: true);
      centred(h.subject, 13);
      final details = [
        if (h.time.trim().isNotEmpty) 'Time: ${h.time.trim()}',
        if (h.marks.trim().isNotEmpty) 'Marks: ${h.marks.trim()}',
      ].join('     ');
      centred(details, 12, after: 12);
    }

    final numbers = doc.questionNumbers;
    final options = doc.optionLabels;
    for (var i = 0; i < doc.paragraphs.length; i++) {
      final p = doc.paragraphs[i];
      if (p.kind == ParaKind.pageBreak) {
        out.add(_Line.breakPage());
        continue;
      }
      final base = TextStyle(
        fontFamily: _family,
        fontFamilyFallback: _fallback,
        fontSize: _pt(p.kind.basePt),
        height: 1.45,
        color: _ink,
        fontWeight: p.kind.bold ? FontWeight.w700 : FontWeight.w400,
        fontStyle: p.kind.italic ? FontStyle.italic : FontStyle.normal,
      );
      final span = p.text.isEmpty
          ? TextSpan(style: base, text: ' ')
          : TextSpan(style: base, children: _runs(p));

      TextPainter? label;
      double labelX = 0;
      final n = numbers[i];
      final optionLabel = options[i];
      if (n != null) {
        label = _labelPainter('${toBanglaNumber(n)}.', base);
      } else if (optionLabel != null) {
        labelX = _pt(20);
        label = _labelPainter('$optionLabel)', base);
      }
      final indent = label == null ? 0.0 : labelX + _gutter;
      out.add(
        _make(
          span: span,
          align: _align(p.align),
          indent: indent,
          width: _contentW - indent,
          label: label,
          labelX: labelX,
          before: _pt(p.kind.beforePt),
          after: _pt(p.kind.afterPt),
        ),
      );
    }
    return out;
  }

  static TextStyle _plain(double pt, {bool bold = false}) => TextStyle(
        fontFamily: _family,
        fontFamilyFallback: _fallback,
        fontSize: _pt(pt),
        height: 1.4,
        color: _ink,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      );

  static TextPainter _labelPainter(String text, TextStyle base) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  static _Line _make({
    required TextSpan span,
    TextAlign align = TextAlign.left,
    double indent = 0,
    double width = _contentW,
    TextPainter? label,
    double labelX = 0,
    double before = 0,
    double after = 0,
  }) {
    final body = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    return _Line(
      body: body,
      label: label,
      bodyX: indent,
      labelX: labelX,
      before: before,
      after: after,
      pageBreak: false,
    );
  }

  static TextAlign _align(ParaAlign a) => switch (a) {
        ParaAlign.left => TextAlign.left,
        ParaAlign.center => TextAlign.center,
        ParaAlign.right => TextAlign.right,
        ParaAlign.justify => TextAlign.justify,
      };

  /// Text runs of a paragraph: consecutive characters with equal styles.
  static List<TextSpan> _runs(DocParagraph p) {
    final out = <TextSpan>[];
    var i = 0;
    while (i < p.text.length) {
      final s = p.styles[i];
      var j = i + 1;
      while (j < p.text.length && p.styles[j] == s) {
        j++;
      }
      final size = s.size;
      out.add(
        TextSpan(
          text: p.text.substring(i, j),
          style: TextStyle(
            fontWeight: s.bold ? FontWeight.w700 : null,
            fontStyle: s.italic ? FontStyle.italic : null,
            decoration: s.underline ? TextDecoration.underline : null,
            fontSize: size == null ? null : _pt(size),
          ),
        ),
      );
      i = j;
    }
    return out;
  }

  // ── Pagination ─────────────────────────────────────────────────

  static List<List<_Placed>> _paginate(List<_Line> lines) {
    const bottom = _pageH - _marginBottom;
    final pages = <List<_Placed>>[[]];
    var y = _marginTop;
    for (final line in lines) {
      if (line.pageBreak) {
        if (pages.last.isNotEmpty) pages.add([]);
        y = _marginTop;
        continue;
      }
      y += line.before;
      if (y + line.height > bottom && pages.last.isNotEmpty) {
        pages.add([]);
        y = _marginTop;
      }
      pages.last.add(_Placed(line, y));
      y += line.height + line.after;
    }
    if (pages.length > 1 && pages.last.isEmpty) pages.removeLast();
    return pages;
  }

  // ── Painting ───────────────────────────────────────────────────

  static Future<Uint8List> _renderPage(
    PaperDocument doc,
    List<_Placed> items,
    int pageNo,
    int pageCount,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, _pageW, _pageH),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, _pageW, _pageH),
      ui.Paint()..color = const Color(0xFFFFFFFF),
    );

    final pageHeader = doc.pageHeader.trim();
    if (pageHeader.isNotEmpty) {
      _paintCentred(canvas, pageHeader, 9, _marginTop - 60);
    }
    final footer = [
      doc.pageFooter.trim(),
      if (doc.showPageNumbers)
        'Page ${toBanglaNumber(pageNo)} of ${toBanglaNumber(pageCount)}',
    ].where((s) => s.isNotEmpty).join('     |     ');
    if (footer.isNotEmpty) {
      _paintCentred(canvas, footer, 9, _pageH - 85);
    }

    for (final placed in items) {
      final line = placed.line;
      line.label?.paint(
        canvas,
        ui.Offset(_marginX + line.labelX, placed.y),
      );
      line.body.paint(canvas, ui.Offset(_marginX + line.bodyX, placed.y));
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(_pageW.round(), _pageH.round());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('Page could not be rendered.');
    return data.buffer.asUint8List();
  }

  static void _paintCentred(
    ui.Canvas canvas,
    String text,
    double pt,
    double y,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _family,
          fontFamilyFallback: _fallback,
          fontSize: _pt(pt),
          color: _muted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _contentW);
    tp.paint(canvas, ui.Offset(_marginX + (_contentW - tp.width) / 2, y));
  }

  /// Sends the rendered PDF to the system print dialog.
  static Future<void> printDocument(PaperDocument doc) async {
    final bytes = await build(doc);
    await Printing.layoutPdf(
      name: doc.title,
      onLayout: (_) async => bytes,
    );
  }

  /// Opens the share sheet with the rendered PDF.
  static Future<void> shareDocument(PaperDocument doc) async {
    final bytes = await build(doc);
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${_safeName(doc.title)}.pdf',
    );
  }

  static String _safeName(String title) {
    final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    return clean.isEmpty ? 'paper' : clean;
  }
}

class _Line {
  final TextPainter body;
  final TextPainter? label;
  final double bodyX;
  final double labelX;
  final double before;
  final double after;
  final bool pageBreak;

  const _Line({
    required this.body,
    required this.label,
    required this.bodyX,
    required this.labelX,
    required this.before,
    required this.after,
    required this.pageBreak,
  });

  factory _Line.breakPage() => _Line(
        body: TextPainter(
          text: const TextSpan(text: ''),
          textDirection: TextDirection.ltr,
        )..layout(),
        label: null,
        bodyX: 0,
        labelX: 0,
        before: 0,
        after: 0,
        pageBreak: true,
      );

  double get height {
    final labelH = label?.height ?? 0;
    return body.height > labelH ? body.height : labelH;
  }
}

class _Placed {
  final _Line line;
  final double y;
  const _Placed(this.line, this.y);
}
