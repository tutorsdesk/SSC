import 'package:flutter/painting.dart';

import '../models/paper_document.dart';

/// A4 page geometry in points. The on-screen page view and the PDF both use
/// these numbers, so a page break falls in the same place in both.
abstract final class PaperPage {
  static const double widthPt = 595;
  static const double heightPt = 842;
  static const double marginLeftPt = 62;
  static const double marginRightPt = 62;
  static const double marginTopPt = 62;
  static const double marginBottomPt = 66;
  static const double contentWidthPt = widthPt - marginLeftPt - marginRightPt;
  static const double contentHeightPt = heightPt - marginTopPt - marginBottomPt;

  /// Width of the number column for questions and options.
  static const double gutterPt = 26;

  /// Extra indent for option lines (under their question).
  static const double optionIndentPt = 18;

  /// Padding inside each table cell.
  static const double cellPadPt = 4;

  /// Height reserved for the "page break" marker on screen.
  static const double breakMarkPt = 14;

  static const String fontFamily = 'Noto Serif Bengali';
  static const List<String> fallbackFonts = ['Hind Siliguri', 'DejaVu Sans'];
  static const Color ink = Color(0xFF111111);
  static const Color muted = Color(0xFF666666);
  static const Color rule = Color(0xFF777777);
}

/// One block placed on a page. `top` is measured from the top of the content
/// area (below the top margin), in pixels at the page scale.
class PageItem {
  /// Index into the document's top-level blocks; -1 for the paper header.
  final int index;
  final double top;
  final double height;
  final bool isBreak;

  const PageItem({
    required this.index,
    required this.top,
    required this.height,
    this.isBreak = false,
  });
}

/// The document split into A4 pages at [scale] pixels per point.
class PaperLayout {
  final double scale;
  final List<List<PageItem>> pages;

  const PaperLayout(this.scale, this.pages);

  int get pageCount => pages.length;

  /// Page (0-based) that holds the top-level block [index], or 0.
  int pageOf(int index) {
    for (var p = 0; p < pages.length; p++) {
      for (final item in pages[p]) {
        if (item.index == index) return p;
      }
    }
    return 0;
  }

  /// Splits the document into pages. Blocks are never split across pages;
  /// a block that does not fit moves to the next page.
  static PaperLayout compute(PaperDocument doc, double scale) {
    final contentW = PaperPage.contentWidthPt * scale;
    final maxH = PaperPage.contentHeightPt * scale;
    final pages = <List<PageItem>>[[]];
    var y = 0.0;

    final headerH = headerHeight(doc, scale);
    if (headerH > 0) {
      pages.last.add(PageItem(index: -1, top: 0, height: headerH));
      y = headerH;
    }

    for (var i = 0; i < doc.paragraphs.length; i++) {
      final p = doc.paragraphs[i];
      if (p.kind == ParaKind.pageBreak) {
        // The marker stays on this page; the next block starts a new page.
        pages.last.add(
          PageItem(
            index: i,
            top: y,
            height: PaperPage.breakMarkPt * scale,
            isBreak: true,
          ),
        );
        pages.add([]);
        y = 0;
        continue;
      }
      final before = p.kind.beforePt * scale;
      final after = p.kind.afterPt * scale;
      final h = blockHeight(p, scale, contentW);
      if (y + before + h + after > maxH && pages.last.isNotEmpty) {
        pages.add([]);
        y = 0;
      }
      pages.last.add(PageItem(index: i, top: y + before, height: h));
      y += before + h + after;
    }

    if (pages.length > 1 && pages.last.isEmpty) pages.removeLast();
    return PaperLayout(scale, pages);
  }
}

/// Style for text of [kind] at [scale] (font size in pixels).
TextStyle paperTextStyle(ParaKind kind, double scale) => TextStyle(
      fontFamily: PaperPage.fontFamily,
      fontFamilyFallback: PaperPage.fallbackFonts,
      fontSize: kind.basePt * scale,
      height: 1.5,
      color: PaperPage.ink,
      fontWeight: kind.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: kind.italic ? FontStyle.italic : FontStyle.normal,
    );

/// Groups runs of equal formatting into spans.
List<TextSpan> paperRuns(DocParagraph p, double scale) {
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
          fontSize: size == null ? null : size * scale,
        ),
      ),
    );
    i = j;
  }
  return out;
}

TextAlign paperAlign(ParaAlign a) => switch (a) {
      ParaAlign.left => TextAlign.left,
      ParaAlign.center => TextAlign.center,
      ParaAlign.right => TextAlign.right,
      ParaAlign.justify => TextAlign.justify,
    };

/// Laid-out text of one block, wrapped to [width] pixels.
TextPainter paragraphPainter(DocParagraph p, double scale, double width) {
  final base = paperTextStyle(p.kind, scale);
  final span = p.text.isEmpty
      ? TextSpan(style: base, text: ' ')
      : TextSpan(style: base, children: paperRuns(p, scale));
  return TextPainter(
    text: span,
    textAlign: paperAlign(p.align),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
}

/// Number or letter label of a question or option.
TextPainter labelPainter(String label, ParaKind kind, double scale) =>
    TextPainter(
      text: TextSpan(
        text: label,
        style: paperTextStyle(kind, scale).copyWith(
          fontWeight: FontWeight.w700,
          fontStyle: FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

/// Left indent of a block's text, in pixels (gutter for questions/options).
double textIndent(DocParagraph p, double scale) {
  if (p.kind == ParaKind.question) return PaperPage.gutterPt * scale;
  if (p.kind == ParaKind.option) {
    return (PaperPage.optionIndentPt + PaperPage.gutterPt) * scale;
  }
  return 0;
}

/// Lines of the paper header (school, exam, subject, time and marks).
class HeaderLine {
  final String text;
  final double pt;
  final bool bold;
  final double afterPt;

  const HeaderLine(this.text, this.pt, this.bold, this.afterPt);
}

List<HeaderLine> headerLinesOf(PaperHeader h) => [
      if (h.school.trim().isNotEmpty) HeaderLine(h.school.trim(), 17, true, 4),
      if (h.exam.trim().isNotEmpty) HeaderLine(h.exam.trim(), 14, true, 4),
      if (h.subject.trim().isNotEmpty)
        HeaderLine(h.subject.trim(), 13, false, 4),
      if (h.details.isNotEmpty) HeaderLine(h.details, 12, false, 12),
    ];

TextPainter headerPainter(HeaderLine line, double scale, double width) =>
    TextPainter(
      text: TextSpan(
        text: line.text,
        style: TextStyle(
          fontFamily: PaperPage.fontFamily,
          fontFamilyFallback: PaperPage.fallbackFonts,
          fontSize: line.pt * scale,
          height: 1.4,
          color: PaperPage.ink,
          fontWeight: line.bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

/// Total height of the header block (including the space after it).
double headerHeight(PaperDocument doc, double scale) {
  final lines = headerLinesOf(doc.header);
  if (lines.isEmpty) return 0;
  final contentW = PaperPage.contentWidthPt * scale;
  var h = 0.0;
  for (final l in lines) {
    final tp = headerPainter(l, scale, contentW);
    h += tp.height + l.afterPt * scale;
  }
  return h;
}

/// Row heights of a table at [scale]; each row fits its tallest cell.
List<double> tableRowHeights(DocTable t, double scale, double contentW) {
  final cols = t.columnCount < 1 ? 1 : t.columnCount;
  final pad = PaperPage.cellPadPt * scale;
  final innerW = contentW / cols - pad * 2;
  return [
    for (final row in t.rows)
      () {
        var h = 0.0;
        for (final cell in row) {
          final ph = paragraphPainter(cell, scale, innerW).height;
          if (ph > h) h = ph;
        }
        return h + pad * 2;
      }(),
  ];
}

/// Height of one block at [scale] for a content width of [contentW] px.
double blockHeight(DocParagraph p, double scale, double contentW) {
  final table = p.table;
  if (table != null) {
    return tableRowHeights(table, scale, contentW).fold<double>(
      0,
      (sum, h) => sum + h,
    );
  }
  final image = p.image;
  if (image != null) return contentW * image.widthFraction * image.aspect;
  if (p.kind == ParaKind.pageBreak) return PaperPage.breakMarkPt * scale;
  final indent = textIndent(p, scale);
  return paragraphPainter(p, scale, contentW - indent).height;
}
