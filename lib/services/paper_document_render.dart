import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/paper_document.dart';
import 'paper_document_layout.dart';

/// Key of the decoded header logo in the image map.
const String headerLogoKey = '__header_logo__';

/// Draws a [PaperDocument] page by page and packs the pages into a PDF.
///
/// The on-screen page view and the PDF both call [paintPage] with the same
/// [PaperLayout], so the page breaks, tables and pictures match in both.
/// Text is shaped by Flutter's text engine, so Bengali conjuncts and vowel
/// signs render correctly.
abstract final class PaperDocumentRender {
  /// Pixels per point used for PDF pages (150 dpi).
  static const double pdfScale = 150 / 72;

  /// Builds the PDF bytes for [doc].
  static Future<Uint8List> build(PaperDocument doc) async {
    final layout = PaperLayout.compute(doc, pdfScale);
    final images = await decodeImages(doc);
    final pdf = pw.Document(title: doc.title);
    for (var i = 0; i < layout.pageCount; i++) {
      final png = await renderPagePng(doc, layout, i, images);
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
    for (final img in images.values) {
      img.dispose();
    }
    return pdf.save();
  }

  /// Renders every page of [doc] as a PNG, with the same layout as [build].
  static Future<List<Uint8List>> renderPages(PaperDocument doc) async {
    final layout = PaperLayout.compute(doc, pdfScale);
    final images = await decodeImages(doc);
    final out = <Uint8List>[];
    try {
      for (var i = 0; i < layout.pageCount; i++) {
        out.add(await renderPagePng(doc, layout, i, images));
      }
    } finally {
      for (final img in images.values) {
        img.dispose();
      }
    }
    return out;
  }

  /// Decodes every picture in [doc] (keyed by block id) for painting.
  static Future<Map<String, ui.Image>> decodeImages(PaperDocument doc) async {
    final out = <String, ui.Image>{};
    final logo = doc.header.logo;
    if (logo != null) {
      try {
        final codec = await ui.instantiateImageCodec(logo.bytes);
        final frame = await codec.getNextFrame();
        out[headerLogoKey] = frame.image;
        codec.dispose();
      } catch (_) {
        // A logo that cannot be decoded is left out of the page.
      }
    }
    for (final p in doc.allTextBlocks) {
      final image = p.image;
      if (image == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(image.bytes);
        final frame = await codec.getNextFrame();
        out[p.id] = frame.image;
        codec.dispose();
      } catch (_) {
        // A picture that cannot be decoded is skipped (drawn as blank).
      }
    }
    return out;
  }

  /// Renders page [pageIndex] (0-based) as PNG at the PDF scale.
  static Future<Uint8List> renderPagePng(
    PaperDocument doc,
    PaperLayout layout,
    int pageIndex,
    Map<String, ui.Image> images,
  ) async {
    final s = layout.scale;
    final w = (PaperPage.widthPt * s).round();
    final h = (PaperPage.heightPt * s).round();
    final recorder = ui.PictureRecorder();
    final canvas =
        ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
    paintPage(canvas, doc, layout, pageIndex, images);
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('Page could not be rendered.');
    return data.buffer.asUint8List();
  }

  /// Paints page [pageIndex] of [layout] onto [canvas] in pixel units
  /// (points multiplied by `layout.scale`). The canvas must already be sized
  /// to the page.
  static void paintPage(
    ui.Canvas canvas,
    PaperDocument doc,
    PaperLayout layout,
    int pageIndex,
    Map<String, ui.Image> images,
  ) {
    final s = layout.scale;
    final pageW = PaperPage.widthPt * s;
    final pageH = PaperPage.heightPt * s;
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, pageW, pageH),
      ui.Paint()..color = const Color(0xFFFFFFFF),
    );

    final contentX = PaperPage.marginLeftPt * s;
    final contentY = PaperPage.marginTopPt * s;
    final contentW = PaperPage.contentWidthPt * s;

    final pageHeader = doc.pageHeader.trim();
    if (pageHeader.isNotEmpty) {
      _paintCentred(canvas, pageHeader, 9, s, contentX,
          (PaperPage.marginTopPt - 30) * s, contentW);
    }
    final footer = [
      doc.pageFooter.trim(),
      if (doc.showPageNumbers)
        'Page ${toBanglaNumber(pageIndex + 1)} of ${toBanglaNumber(layout.pageCount)}',
    ].where((t) => t.isNotEmpty).join('     |     ');
    if (footer.isNotEmpty) {
      _paintCentred(canvas, footer, 9, s, contentX,
          (PaperPage.heightPt - 44) * s, contentW);
    }

    final numbers = doc.questionNumbers;
    final options = doc.optionLabels;
    final paragraphs = doc.paragraphs;

    for (final item in layout.pages[pageIndex]) {
      final y = contentY + item.top;
      if (item.index == -1) {
        _paintHeader(
          canvas,
          doc.header,
          s,
          contentX,
          contentY,
          contentW,
          images[headerLogoKey],
        );
        continue;
      }
      if (item.isBreak) continue;
      final p = paragraphs[item.index];
      final table = p.table;
      if (table != null) {
        _paintTable(canvas, table, s, contentX, y, contentW);
        continue;
      }
      final image = p.image;
      if (image != null) {
        _paintImage(canvas, image, images[p.id], s, contentX, y, contentW);
        continue;
      }
      final n = numbers[item.index];
      final optionLabel = options[item.index];
      double labelX = 0;
      TextPainter? label;
      if (n != null) {
        label = labelPainter('${toBanglaNumber(n)}.', p.kind, s);
      } else if (optionLabel != null) {
        labelX = PaperPage.optionIndentPt * s;
        label = labelPainter('$optionLabel)', p.kind, s);
      }
      label?.paint(canvas, ui.Offset(contentX + labelX, y));
      final body = paragraphPainter(p, s, contentW - textIndent(p, s));
      body.paint(canvas, ui.Offset(contentX + textIndent(p, s), y));
    }
  }

  static void _paintHeader(
    ui.Canvas canvas,
    PaperHeader header,
    double s,
    double x,
    double y,
    double width,
    ui.Image? logoImage,
  ) {
    var cy = y;
    final logo = header.logo;
    if (logo != null) {
      final w = width * logo.widthFraction;
      final h = w * logo.aspect;
      final left = switch (header.logoAlign) {
        ParaAlign.right => x + width - w,
        ParaAlign.center => x + (width - w) / 2,
        _ => x,
      };
      if (logoImage != null) {
        canvas.drawImageRect(
          logoImage,
          ui.Rect.fromLTWH(
            0,
            0,
            logoImage.width.toDouble(),
            logoImage.height.toDouble(),
          ),
          ui.Rect.fromLTWH(left, cy, w, h),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
      }
      cy += h + headerLogoGapPt * s;
    }
    for (final line in headerLinesOf(header)) {
      final tp = headerPainter(line, s, width);
      tp.paint(canvas, ui.Offset(x, cy));
      cy += tp.height + line.afterPt * s;
    }
  }

  static void _paintTable(
    ui.Canvas canvas,
    DocTable table,
    double s,
    double x,
    double y,
    double width,
  ) {
    final cols = table.columnCount < 1 ? 1 : table.columnCount;
    final cellW = width / cols;
    final pad = PaperPage.cellPadPt * s;
    final heights = tableRowHeights(table, s, width);
    final line = ui.Paint()
      ..color = PaperPage.rule
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 0.8 * s;
    var rowY = y;
    for (var r = 0; r < table.rows.length; r++) {
      final row = table.rows[r];
      for (var c = 0; c < row.length; c++) {
        final cx = x + c * cellW;
        final rect = ui.Rect.fromLTWH(cx, rowY, cellW, heights[r]);
        canvas.drawRect(rect, line);
        final tp = paragraphPainter(row[c], s, cellW - pad * 2);
        tp.paint(canvas, ui.Offset(cx + pad, rowY + pad));
      }
      rowY += heights[r];
    }
  }

  static void _paintImage(
    ui.Canvas canvas,
    DocImage image,
    ui.Image? decoded,
    double s,
    double x,
    double y,
    double width,
  ) {
    final w = width * image.widthFraction;
    final h = w * image.aspect;
    final dst = ui.Rect.fromLTWH(x + (width - w) / 2, y, w, h);
    if (decoded == null) {
      canvas.drawRect(
        dst,
        ui.Paint()
          ..color = PaperPage.rule
          ..style = ui.PaintingStyle.stroke,
      );
      return;
    }
    final src = ui.Rect.fromLTWH(
      0,
      0,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    canvas.drawImageRect(
      decoded,
      src,
      dst,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
  }

  static void _paintCentred(
    ui.Canvas canvas,
    String text,
    double pt,
    double s,
    double x,
    double y,
    double width,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: PaperPage.fontFamily,
          fontFamilyFallback: PaperPage.fallbackFonts,
          fontSize: pt * s,
          color: PaperPage.muted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    tp.paint(canvas, ui.Offset(x + (width - tp.width) / 2, y));
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
