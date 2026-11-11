import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'local_account_scope.dart';
import 'local_diagnostics.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One question paper the tutor added to the app.
///
/// `kind` is either `'images'` (each page is a photo/scan, stored as
/// `{id}_p1.jpg`, `{id}_p2.jpg`, …) or `'pdf'` (a single `{id}.pdf`).
/// `thumb.jpg` is a small preview of page 1.
class PaperEntry {
  final String id;
  final String title;
  final String subject;
  final String year;
  final String kind;
  final int pages;
  final DateTime createdAt;

  const PaperEntry({
    required this.id,
    required this.title,
    required this.subject,
    required this.year,
    required this.kind,
    required this.pages,
    required this.createdAt,
  });

  String get kindLabel =>
      kind == 'pdf' ? 'PDF' : (kind == 'saved' ? 'Saved' : 'ছবি');

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'year': year,
        'kind': kind,
        'pages': pages,
        'createdAt': createdAt.toIso8601String(),
      };

  static PaperEntry fromJson(Map<String, dynamic> m) => PaperEntry(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        subject: m['subject'] as String? ?? '',
        year: m['year'] as String? ?? '',
        kind: m['kind'] as String? ?? 'images',
        pages: m['pages'] as int? ?? 1,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// One MCQ of a saved paper (kept so the key can be verified on screen).
class SavedQuestion {
  final String text;
  final List<String> options;
  final int answer; // 0–3

  const SavedQuestion({
    required this.text,
    required this.options,
    required this.answer,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'options': options,
        'answer': answer,
      };

  static SavedQuestion fromJson(Map<String, dynamic> m) => SavedQuestion(
        text: m['text'] as String? ?? '',
        options: (m['options'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        answer: (m['answer'] as num? ?? 0).toInt(),
      );
}

/// A question paper saved from the in-app builder (Question Paper / Custom
/// Paper screen). Unlike the photo/PDF uploads, a saved paper carries its
/// MCQ list and answer key, so the OMR scanner can grade sheets against it
/// without the teacher retyping the key.
class SavedPaper {
  final String id;
  final String title;
  final String subject; // display name
  final String subjectId;
  final String subjectCode; // e.g. ১০৯
  final String setCode; // ক/খ/গ/ঘ or '—'
  final int total;
  final List<int> key; // option index (0–3) per MCQ
  final List<SavedQuestion> questions;
  final DateTime createdAt;

  /// Rendered page count (p1.jpg…pN.jpg in the entry dir). 0 for entries
  /// saved before pages were stored.
  final int pages;

  /// The whole paper as an editable document (every question type). Null
  /// for papers saved before full editing; those edit as MCQs only.
  final Map<String, dynamic>? document;

  const SavedPaper({
    required this.id,
    required this.title,
    required this.subject,
    required this.subjectId,
    required this.subjectCode,
    required this.setCode,
    required this.total,
    required this.key,
    required this.questions,
    required this.createdAt,
    this.pages = 0,
    this.document,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'subjectId': subjectId,
        'subjectCode': subjectCode,
        'setCode': setCode,
        'total': total,
        'key': key,
        'questions': [for (final q in questions) q.toJson()],
        'createdAt': createdAt.toIso8601String(),
        'pages': pages,
        if (document != null) 'document': document,
      };

  static SavedPaper fromJson(Map<String, dynamic> m) => SavedPaper(
        id: m['id'] as String? ?? '',
        title: m['title'] as String? ?? '',
        subject: m['subject'] as String? ?? '',
        subjectId: m['subjectId'] as String? ?? '',
        subjectCode: m['subjectCode'] as String? ?? '',
        setCode: m['setCode'] as String? ?? '—',
        total: m['total'] as int? ?? 0,
        key: (m['key'] as List? ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        questions: (m['questions'] as List? ?? const [])
            .map((e) =>
                SavedQuestion.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
            DateTime.now(),
        pages: m['pages'] as int? ?? 0,
        document: m['document'] is Map
            ? (m['document'] as Map).cast<String, dynamic>()
            : null,
      );
}

class PaperLibrary {
  PaperLibrary._();

  static const _indexName = 'index.json';
  static final _storageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _backupFilePattern = RegExp(r'^p[1-9][0-9]*\.jpg$');

  /// IDs are used as directory names. Keep imported/indexed values to the
  /// same narrow form produced by the app so a crafted backup cannot escape
  /// the paper-library root through `..` or path separators.
  static bool isSafeStorageId(String value) =>
      _storageIdPattern.hasMatch(value);

  static bool _isSafeBackupFile(String value) =>
      value == 'paper.json' ||
      value == 'thumb.jpg' ||
      value == 'doc.pdf' ||
      _backupFilePattern.hasMatch(value);

  static Future<Directory> root() async {
    final appDoc = await getApplicationDocumentsDirectory();
    final legacy = Directory(
      '${appDoc.path}${Platform.pathSeparator}tutors_desk_papers',
    );
    final dir = Directory(
      '${legacy.path}${Platform.pathSeparator}accounts'
      '${Platform.pathSeparator}${LocalAccountScope.id}',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await _claimLegacyLibrary(legacy, dir);
    return dir;
  }

  /// Assign data written by pre-account-scoping builds to the account that is
  /// signed in during the upgrade. It is moved once, so later accounts can
  /// never see or claim the same papers.
  static Future<void> _claimLegacyLibrary(
    Directory legacy,
    Directory scoped,
  ) async {
    final marker = File(
      '${scoped.path}${Platform.pathSeparator}.legacy_claimed',
    );
    if (marker.existsSync()) return;
    final oldIndex = File('${legacy.path}${Platform.pathSeparator}$_indexName');
    final newIndex = File('${scoped.path}${Platform.pathSeparator}$_indexName');
    if (oldIndex.existsSync() && !newIndex.existsSync()) {
      try {
        final raw = json.decode(await oldIndex.readAsString());
        if (raw is List) {
          await oldIndex.copy(newIndex.path);
          for (final item in raw) {
            if (item is! Map) continue;
            final id = item['id']?.toString() ?? '';
            if (!isSafeStorageId(id)) continue;
            final oldDir = Directory(
              '${legacy.path}${Platform.pathSeparator}$id',
            );
            final newDir = Directory(
              '${scoped.path}${Platform.pathSeparator}$id',
            );
            if (oldDir.existsSync() && !newDir.existsSync()) {
              await oldDir.rename(newDir.path);
            }
          }
          await oldIndex.delete();
        }
      } catch (_) {
        // Keep recovery data untouched if migration cannot complete.
      }
    }
    try {
      await marker.writeAsString(LocalAccountScope.id, flush: true);
    } catch (_) {}
  }

  static Future<File> _indexFile() async {
    final dir = await root();
    final correct = File('${dir.path}${Platform.pathSeparator}$_indexName');
    // Older builds omitted the separator. Copy once, keeping the old file as
    // recovery data so an upgrade never loses a teacher's saved papers.
    final legacy = File('${dir.path}$_indexName');
    if (!await correct.exists() && await legacy.exists()) {
      await legacy.copy(correct.path);
    }
    return correct;
  }

  static Future<List<PaperEntry>> loadEntries() async {
    final f = await _indexFile();
    if (!f.existsSync()) return const [];
    try {
      final raw = json.decode(f.readAsStringSync());
      if (raw is! List) return const [];
      final entries = <PaperEntry>[];
      for (final item in raw) {
        try {
          if (item is! Map) continue;
          final entry = PaperEntry.fromJson(item.cast<String, dynamic>());
          if (isSafeStorageId(entry.id)) entries.add(entry);
        } catch (_) {
          // One damaged/imported row must not hide every valid saved paper.
        }
      }
      entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveEntries(List<PaperEntry> entries) async {
    final f = await _indexFile();
    await f.writeAsString(json.encode([for (final e in entries) e.toJson()]));
  }

  static Future<Directory> _dirFor(String id) async {
    if (!isSafeStorageId(id)) throw ArgumentError.value(id, 'id');
    final dir = Directory((await root()).path + Platform.pathSeparator + id);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Adds a paper from photos (one photo per page, in order).
  static Future<PaperEntry> addFromImages({
    required String title,
    required String subject,
    required String year,
    required List<Uint8List> pages,
  }) async {
    if (pages.isEmpty) {
      throw Exception('Add at least one page photo.');
    }
    final id = 'p_${DateTime.now().microsecondsSinceEpoch}';
    final dir = await _dirFor(id);
    final norm = <Uint8List>[];
    for (final raw in pages) {
      norm.add(await _normalizeJpeg(raw));
    }
    for (var i = 0; i < norm.length; i++) {
      await File(
        '${dir.path}${Platform.pathSeparator}p${i + 1}.jpg',
      ).writeAsBytes(norm[i]);
    }
    // Thumbnail from the *normalized* first page so it matches what is
    // stored and printed.
    final thumb = await _thumbFrom(norm.first);
    await File(
      '${dir.path}${Platform.pathSeparator}thumb.jpg',
    ).writeAsBytes(thumb);

    final entry = PaperEntry(
      id: id,
      title: title,
      subject: subject,
      year: year,
      kind: 'images',
      pages: norm.length,
      createdAt: DateTime.now(),
    );
    final all = await loadEntries();
    await _saveEntries([entry, ...all]);
    unawaited(PaperBackup.autoSave());
    return entry;
  }

  /// Adds a paper from a PDF file.
  static Future<PaperEntry> addFromPdf({
    required String title,
    required String subject,
    required String year,
    required Uint8List bytes,
    int pages = 0,
  }) async {
    if (bytes.isEmpty) throw Exception('The PDF file is empty.');
    final id = 'p_${DateTime.now().microsecondsSinceEpoch}';
    final dir = await _dirFor(id);
    await File(
      '${dir.path}${Platform.pathSeparator}doc.pdf',
    ).writeAsBytes(bytes);
    // No raster thumbnail for PDFs — the list shows a document icon.

    final entry = PaperEntry(
      id: id,
      title: title,
      subject: subject,
      year: year,
      kind: 'pdf',
      pages: pages > 0 ? pages : 1,
      createdAt: DateTime.now(),
    );
    final all = await loadEntries();
    await _saveEntries([entry, ...all]);
    unawaited(PaperBackup.autoSave());
    return entry;
  }

  static Future<void> deleteEntry(String id) async {
    final dir = Directory((await root()).path + Platform.pathSeparator + id);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final all = (await loadEntries())..removeWhere((e) => e.id == id);
    await _saveEntries(all);
    unawaited(PaperBackup.autoSave());
  }

  /// Stores a builder paper (metadata + answer key) under kind 'saved'.
  /// When [pageImages] (the builder's rendered page PNGs) are given, the
  /// paper is also saved as viewable pages (p1.jpg…, thumb.jpg) — the
  /// same layout [addFromImages] uses — so it can be viewed, printed,
  /// and shared from the Saved tab.
  static Future<SavedPaper> addSavedPaper(
    SavedPaper paper, {
    List<Uint8List>? pageImages,
  }) async {
    final dir = await _dirFor(paper.id);
    var pages = paper.pages;
    if (pageImages != null && pageImages.isNotEmpty) {
      final norm = <Uint8List>[];
      for (final raw in pageImages) {
        try {
          norm.add(await _normalizeJpeg(raw));
        } catch (_) {
          throw StateError(
            'A page could not be saved. No incomplete paper was added to your library.',
          );
        }
      }
      if (norm.isNotEmpty) {
        for (var i = 0; i < norm.length; i++) {
          await File(
            '${dir.path}${Platform.pathSeparator}p${i + 1}.jpg',
          ).writeAsBytes(norm[i]);
        }
        final thumb = await _thumbFrom(norm.first);
        await File(
          '${dir.path}${Platform.pathSeparator}thumb.jpg',
        ).writeAsBytes(thumb);
        pages = norm.length;
      }
    }
    final saved = SavedPaper(
      id: paper.id,
      title: paper.title,
      subject: paper.subject,
      subjectId: paper.subjectId,
      subjectCode: paper.subjectCode,
      setCode: paper.setCode,
      total: paper.total,
      key: paper.key,
      questions: paper.questions,
      createdAt: paper.createdAt,
      pages: pages,
    );
    await File(
      '${dir.path}${Platform.pathSeparator}paper.json',
    ).writeAsString(json.encode(saved.toJson()));
    final entry = PaperEntry(
      id: paper.id,
      title: paper.title,
      subject: paper.subject,
      year: '',
      kind: 'saved',
      pages: pages,
      createdAt: paper.createdAt,
    );
    final all = await loadEntries();
    await _saveEntries([entry, ...all]);
    unawaited(PaperBackup.autoSave());
    return saved;
  }

  /// Replaces the viewable pages of a saved paper with [rawPages] (PNG or
  /// JPEG, one per page). The answer key, questions and other fields are kept.
  static Future<void> replaceSavedPages(
    String id,
    List<Uint8List> rawPages,
  ) async {
    if (rawPages.isEmpty) throw StateError('The paper has no pages.');
    final current = await savedPaper(id);
    if (current == null) throw StateError('Saved paper not found.');
    final dir = await _dirFor(id);
    final sep = Platform.pathSeparator;
    final norm = <Uint8List>[];
    for (final raw in rawPages) {
      norm.add(await _normalizeJpeg(raw));
    }
    for (var i = 0; i < norm.length; i++) {
      await File('${dir.path}${sep}p${i + 1}.jpg').writeAsBytes(norm[i]);
    }
    await File('${dir.path}${sep}thumb.jpg')
        .writeAsBytes(await _thumbFrom(norm.first));
    for (var i = norm.length + 1; i <= current.pages; i++) {
      final stale = File('${dir.path}${sep}p$i.jpg');
      if (stale.existsSync()) await stale.delete();
    }
    final updated = SavedPaper(
      id: current.id,
      title: current.title,
      subject: current.subject,
      subjectId: current.subjectId,
      subjectCode: current.subjectCode,
      setCode: current.setCode,
      total: current.total,
      key: current.key,
      questions: current.questions,
      createdAt: current.createdAt,
      pages: norm.length,
    );
    await File('${dir.path}${sep}paper.json')
        .writeAsString(json.encode(updated.toJson()));
    final entries = await loadEntries();
    await _saveEntries([
      for (final e in entries)
        if (e.id == id)
          PaperEntry(
            id: e.id,
            title: e.title,
            subject: e.subject,
            year: e.year,
            kind: e.kind,
            pages: norm.length,
            createdAt: e.createdAt,
          )
        else
          e,
    ]);
    unawaited(PaperBackup.autoSave());
  }

  /// The saved paper (with its answer key) stored under entry [id], if any.
  static Future<SavedPaper?> savedPaper(String id) async {
    final f = File(
      (await _dirFor(id)).path + Platform.pathSeparator + 'paper.json',
    );
    if (!f.existsSync()) return null;
    try {
      return SavedPaper.fromJson(
        (json.decode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// All papers saved from the in-app builder (newest first) — the source
  /// list for the OMR scanner's answer-key picker. Photo/PDF uploads are
  /// intentionally excluded.
  static Future<List<SavedPaper>> loadSavedPapers() async {
    final entries =
        (await loadEntries()).where((e) => e.kind == 'saved').toList();
    final out = <SavedPaper>[];
    for (final e in entries) {
      final p = await savedPaper(e.id);
      if (p != null) out.add(p);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  static Future<Uint8List?> pageBytes(String id, int page) async {
    final f = File(
      (await _dirFor(id)).path + Platform.pathSeparator + 'p${page}.jpg',
    );
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  static Future<Uint8List?> pdfBytes(String id) async {
    final f = File(
      (await _dirFor(id)).path + Platform.pathSeparator + 'doc.pdf',
    );
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  static Future<Uint8List?> thumbBytes(String id) async {
    final f = File(
      (await _dirFor(id)).path + Platform.pathSeparator + 'thumb.jpg',
    );
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  static Future<pw.Document> _imageDocument(PaperEntry entry) async {
    if (entry.pages <= 0) throw StateError('This paper has no pages.');
    final doc = pw.Document();
    for (var i = 1; i <= entry.pages; i++) {
      final bytes = await pageBytes(entry.id, i);
      if (bytes == null) {
        throw StateError('Page $i of this paper is missing.');
      }
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            pw.MemoryImage(bytes),
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.contain,
          ),
        ),
      );
    }
    return doc;
  }

  /// Prints (or shares, when the system print service is unavailable) the
  /// paper. Image papers are assembled into an A4 PDF on the fly.
  static Future<void> printEntry(PaperEntry entry) async {
    if (entry.kind == 'pdf') {
      final bytes = await pdfBytes(entry.id);
      if (bytes == null) throw Exception('PDF not found.');
      await _layoutOrShare(bytes, '${_safeName(entry.title)}.pdf');
      return;
    }
    final doc = await _imageDocument(entry);
    final bytes = await doc.save();
    await _layoutOrShare(bytes, '${_safeName(entry.title)}.pdf');
  }

  /// Hands the paper to the system share sheet (PDF in both kinds).
  static Future<void> shareEntry(PaperEntry entry) async {
    if (entry.kind == 'pdf') {
      final bytes = await pdfBytes(entry.id);
      if (bytes == null) throw Exception('PDF not found.');
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${_safeName(entry.title)}.pdf',
      );
      return;
    }
    final doc = await _imageDocument(entry);
    final bytes = await doc.save();
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${_safeName(entry.title)}.pdf',
    );
  }

  static Future<void> _layoutOrShare(Uint8List bytes, String filename) async {
    try {
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (_) {
      await Printing.sharePdf(bytes: bytes, filename: filename);
    }
  }

  static String _safeName(String title) {
    final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    return clean.isEmpty ? 'paper' : clean;
  }

  // ═══════════ image normalisation ═══════════

  /// Decodes a picked photo, applies its EXIF orientation and re-encodes as
  /// a compact upright JPEG. Display, thumbnails and PDF assembly then all
  /// use the same correct-upright bytes.
  static Future<Uint8List> _normalizeJpeg(Uint8List raw) =>
      compute(_normalizeJpegCore, raw);

  static Future<Uint8List> _thumbFrom(Uint8List page) =>
      compute(_thumbCore, page);

  // ═══════════ EXIF orientation (JPEG only) ═══════════

  /// Returns the EXIF Orientation tag (1–8) of a JPEG, or null.
  ///
  /// Hand-rolled (≈40 lines) so the app never needs a native EXIF library:
  /// walk JPEG segments to APP1, verify the `Exif\0\0` payload, read the
  /// first IFD and return tag 0x0112.
  static int? exifOrientation(Uint8List j) {
    if (j.length < 4 || j[0] != 0xFF || j[1] != 0xD8) return null;
    int jpegU16(int o) => (j[o] << 8) | j[o + 1];
    var p = 2;
    while (p + 4 <= j.length) {
      if (j[p] != 0xFF) {
        p++;
        continue;
      }
      final marker = j[p + 1];
      if (marker == 0xDA) break; // start of scan — no EXIF before this
      if (marker >= 0xD0 && marker <= 0xD7) continue; // RST: no length
      final len = jpegU16(p + 2);
      if (marker == 0xE1) {
        final exif = p + 4; // APP1 payload start: "Exif\0\0" + TIFF header
        // TIFF header: byte order (II/MM), 0x002A, offset to first IFD.
        final tiffStart = exif + 6;
        if (tiffStart + 8 <= j.length &&
            j[exif] == 0x45 &&
            j[exif + 1] == 0x78 &&
            j[exif + 2] == 0x69 &&
            j[exif + 3] == 0x66 &&
            j[exif + 4] == 0x00 &&
            j[exif + 5] == 0x00 &&
            (j[tiffStart + 2] == 0x2A || j[tiffStart + 3] == 0x2A)) {
          final little = j[tiffStart] == 0x49; // 'I'
          int u16e(int o) =>
              little ? (j[o] | (j[o + 1] << 8)) : ((j[o] << 8) | j[o + 1]);
          int u32e(int o) => little
              ? (j[o] | (j[o + 1] << 8) | (j[o + 2] << 16) | (j[o + 3] << 24))
              : ((j[o] << 24) | (j[o + 1] << 16) | (j[o + 2] << 8) | j[o + 3]);
          final ifdOff = u32e(tiffStart + 4);
          final ifd = tiffStart + ifdOff; // TIFF offsets are relative
          if (ifd + 2 <= j.length) {
            final n = u16e(ifd);
            for (var i = 0; i < n; i++) {
              final e = ifd + 2 + i * 12;
              if (e + 12 > j.length) break;
              if (u16e(e) == 0x0112) {
                return u16e(e + 8); // Orientation is SHORT — inline value
              }
            }
          }
        }
      }
      p += 2 + len;
    }
    return null;
  }

  static img.Image _applyOrientation(img.Image im, int o) {
    switch (o) {
      case 2:
        return img.flipHorizontal(im);
      case 3:
        return img.copyRotate(im, angle: 180);
      case 4:
        return img.flipVertical(im);
      case 5:
        return img.flipHorizontal(img.copyRotate(im, angle: 90));
      case 6:
        return img.copyRotate(im, angle: 90);
      case 7:
        return img.flipHorizontal(img.copyRotate(im, angle: 270));
      case 8:
        return img.copyRotate(im, angle: 270);
      default:
        return im;
    }
  }
}

/// Core of [PaperLibrary._normalizeJpeg] — runs in a background isolate via
/// compute() so decoding + re-encoding a full-size photo never blocks the
/// UI thread (no lag / "app not responding" while saving or uploading).
Uint8List _normalizeJpegCore(Uint8List raw) {
  final image = img.decodeImage(raw);
  if (image == null) return raw; // not decodable — keep as-is, best effort
  var im = image;
  final orientation = PaperLibrary.exifOrientation(raw);
  if (orientation != null) {
    im = PaperLibrary._applyOrientation(im, orientation);
  }
  // Cap long side at 2200 px — plenty for print, keeps storage small.
  const maxSide = 2200;
  final side = im.width > im.height ? im.width : im.height;
  if (side > maxSide) {
    final s = maxSide / side;
    im = img.copyResize(
      im,
      width: (im.width * s).round(),
      height: (im.height * s).round(),
    );
  }
  return img.encodeJpg(im, quality: 85);
}

/// Core of [PaperLibrary._thumbFrom] — runs in a background isolate via
/// compute().
Uint8List _thumbCore(Uint8List page) {
  final image = img.decodeImage(page);
  if (image == null) return page;
  final s = 360.0 / (image.width > image.height ? image.width : image.height);
  final im = s < 1
      ? img.copyResize(
          image,
          width: (image.width * s).round(),
          height: (image.height * s).round(),
        )
      : image;
  return img.encodeJpg(im, quality: 78);
}

/// Automatic backup / restore for the whole paper library.
///
/// Android deletes the app's private folder when the app is uninstalled, so
/// this keeps an automatic copy of the whole library (saved MCQ papers with
/// keys, photo pages, PDFs) in the shared Download folder:
/// `Download/TutorsDesk/tutors_desk_backup.json`. That needs the one-time
/// "All files access" permission; after that it is fully automatic:
/// every change is re-saved, and on startup an empty library (fresh
/// install) is restored on its own.
class PaperBackup {
  PaperBackup._();

  static const _channel = MethodChannel('com.tutorsdesk.app/storage');
  static const _dirName = 'TutorsDesk';
  static String get _fileName =>
      'tutors_desk_backup_${LocalAccountScope.id}.json';

  /// Whether the app may write into the shared Download folder.
  static Future<bool> permissionGranted() async {
    try {
      return (await _channel.invokeMethod<bool>('canManageAllFiles')) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the one-time system settings page for the permission.
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<bool>('requestManageAllFiles');
    } catch (_) {
      // Platform side unavailable — nothing to do.
    }
  }

  /// Path of the auto-backup file, or null when it cannot be written.
  ///
  /// Lives in the app's own external folder, which is always writable
  /// under scoped storage. The shared Download folder (the old location)
  /// needs the "all files access" permission, which users often never
  /// grant — so auto-save was a silent no-op on many phones.
  static Future<String?> _backupPath() async {
    final override = debugBaseDir;
    if (override != null) {
      try {
        final dir = await override();
        if (dir == null) return null;
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return '${dir.path}/$_fileName';
      } catch (_) {
        return null;
      }
    }
    try {
      Directory? base;
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {}
      base ??= await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/$_dirName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}/$_fileName';
    } catch (_) {
      return null;
    }
  }

  /// Backup location in the shared Download folder — the copy that survives
  /// an uninstall, written by [_writeSharedCopy] and readable here after a
  /// reinstall.
  static Future<File?> _legacyBackupFile() async {
    try {
      final base = await _channel.invokeMethod<String>('externalStorageDir');
      if (base == null) return null;
      final f = File('$base/Download/$_dirName/$_fileName');
      return f.existsSync() ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// The whole library packed into one JSON document.
  static Future<Map<String, dynamic>> _payload() async {
    final rootDir = await PaperLibrary.root();
    final entries = await PaperLibrary.loadEntries();
    final files = <String, String>{};
    for (final e in entries) {
      final dir = Directory('${rootDir.path}${Platform.pathSeparator}${e.id}');
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync()) {
        if (f is File) {
          final name = f.path.split(Platform.pathSeparator).last;
          files['${e.id}/$name'] = base64Encode(await f.readAsBytes());
        }
      }
    }
    return {
      'app': 'tutors_desk',
      'version': 2,
      'ownerId': LocalAccountScope.id,
      'exportedAt': DateTime.now().toIso8601String(),
      'entries': [for (final e in entries) e.toJson()],
      'files': files,
    };
  }

  /// Test seam: replaces app-storage resolution so tests do not depend on how
  /// a particular path_provider version resolves platform directories.
  /// Always null in the app.
  @visibleForTesting
  static Future<Directory?> Function()? debugBaseDir;

  /// Takes one snapshot of the whole library.
  ///
  /// Writes the in-app copy (no permission needed, but Android deletes it on
  /// uninstall) and then the shared `Download/TutorsDesk` copy through
  /// MediaStore — the one a reinstall can find, needing no permission on
  /// Android 10+. The two are independent: a failure in one must never skip
  /// the other. Silent no-op when storage is unavailable, because auto-save
  /// must never disturb the user.
  static Future<void>? _saveWorker;
  static bool _saveRequested = false;

  static Future<void> autoSave() {
    // A burst of edits can request several full-library snapshots in one
    // frame. Coalesce those requests into one worker and, if data changes
    // while it runs, one final up-to-date pass. This keeps backup automatic
    // without competing disk/base64 work causing UI jank.
    _saveRequested = true;
    return _saveWorker ??= _drainAutoSaves().whenComplete(() {
      _saveWorker = null;
      if (_saveRequested) unawaited(autoSave());
    });
  }

  static Future<void> _drainAutoSaves() async {
    while (_saveRequested) {
      _saveRequested = false;
      await _saveOnce();
    }
  }

  static Future<void> _saveOnce() async {
    String document;
    try {
      final payload = await _payload();
      if (((payload['entries'] as List?) ?? const []).isEmpty &&
          await _backupExists()) {
        // An empty library must never replace a real backup: a fresh install,
        // a wiped library or a transient read failure would otherwise erase
        // the teacher's papers — including the copy a reinstall needs.
        return;
      }
      document = json.encode(payload);
    } catch (_) {
      return;
    }
    try {
      final path = await _backupPath();
      if (path != null) {
        final tmp = '$path.tmp';
        await File(tmp).writeAsString(document, flush: true);
        File(tmp).renameSync(path); // atomic: readers never see a half file
      }
    } catch (_) {
      // The shared copy below is still attempted.
    }
    await _writeSharedCopy(document);
  }

  /// Copies the current library backup into the shared Download folder and
  /// returns its location, or null when this device cannot (for example
  /// pre-Android 10 without the all-files permission).
  static Future<String?> exportToDownload() async {
    try {
      final payload = await _payload();
      if (((payload['entries'] as List?) ?? const []).isEmpty &&
          await _backupExists()) {
        return null; // keep the existing backup instead of emptying it
      }
      return await _writeSharedCopy(json.encode(payload));
    } catch (_) {
      return null;
    }
  }

  /// True when any backup copy already exists, in-app or shared.
  static Future<bool> _backupExists() async {
    try {
      final path = await _backupPath();
      if (path != null && File(path).existsSync()) return true;
      return await _legacyBackupFile() != null;
    } catch (_) {
      return false;
    }
  }

  /// MediaStore is the sanctioned no-permission route on Android 10+ and is
  /// where [tryAutoRestore] looks after a reinstall. Falls back to a temporary
  /// source file when app storage is unavailable, so the uninstall-safe copy
  /// does not depend on the in-app copy succeeding.
  /// Shared copies are serialized: an automatic save and a manual export can
  /// overlap, and two writers must not race over one temporary source file.
  static Future<void> _sharedWrites = Future.value();

  static Future<String?> _writeSharedCopy(String document) {
    final result = _sharedWrites.then((_) => _writeSharedCopyNow(document));
    _sharedWrites = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<String?> _writeSharedCopyNow(String document) async {
    File? temporary;
    try {
      var source = await _backupPath();
      if (source == null) {
        // Unique per call, so a concurrent copy can never read a file another
        // call has already deleted.
        temporary = File(
          '${Directory.systemTemp.path}/$_fileName.'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        source = temporary.path;
      }
      await File(source).writeAsString(document, flush: true);
      final display = await _channel.invokeMethod<String>('copyToDownloads', {
        'source': source,
        'name': _fileName,
        'mime': 'application/json',
        'relativePath': 'Download/$_dirName',
      });
      return display?.trim().isNotEmpty == true
          ? 'Download/$_dirName/$_fileName'
          : null;
    } catch (_) {
      return null;
    } finally {
      try {
        temporary?.deleteSync();
      } catch (_) {}
    }
  }

  /// Startup hook: if the local library is empty (fresh install / wiped)
  /// and a backup exists, restore it automatically. Returns the number of
  /// papers restored (0 = nothing to do).
  static Future<int> tryAutoRestore() async {
    try {
      final current = await PaperLibrary.loadEntries();
      if (current.isNotEmpty) return 0;
      final path = await _backupPath();
      if (path != null) {
        final f = File(path);
        if (f.existsSync()) return await restore(f);
      }
      // Fresh installs may still have a legacy-location backup.
      final legacy = await _legacyBackupFile();
      if (legacy != null) return await restore(legacy);
      return 0;
    } catch (error, stack) {
      // A failed restore must stay silent to the teacher, but it must not be
      // invisible to diagnosis either.
      unawaited(LocalDiagnostics.record(error, stack, scope: 'workflow'));
      return 0;
    }
  }

  /// Restores a file produced by [autoSave] into the current library.
  /// Merges: papers already present keep their current entry, missing ones
  /// are added; stored files are (re)written from the backup. Returns the
  /// number of papers added.
  static Future<int> restore(File f) async {
    final m =
        (json.decode(f.readAsStringSync()) as Map).cast<String, dynamic>();
    if (m['app'] != 'tutors_desk' ||
        m['entries'] is! List ||
        m['files'] is! Map) {
      throw Exception("That is not a Tutor's Desk backup file.");
    }
    final ownerId = m['ownerId']?.toString();
    if (ownerId != null && ownerId != LocalAccountScope.id) {
      throw StateError('This backup belongs to a different account.');
    }
    // Parse and validate the index before writing any file. A backup is an
    // import boundary, so malformed rows are ignored rather than becoming
    // directory names or aborting restoration of every valid paper.
    final restored = <PaperEntry>[];
    for (final raw in m['entries'] as List) {
      try {
        if (raw is! Map) continue;
        final entry = PaperEntry.fromJson(raw.cast<String, dynamic>());
        if (PaperLibrary.isSafeStorageId(entry.id)) restored.add(entry);
      } catch (_) {}
    }
    final restoredIds = restored.map((entry) => entry.id).toSet();
    final rootDir = await PaperLibrary.root();
    final files = (m['files'] as Map).cast<String, dynamic>();
    files.forEach((key, value) {
      final parts = key.split('/');
      if (parts.length != 2) return;
      final id = parts[0];
      final name = parts[1];
      if (!restoredIds.contains(id) || !PaperLibrary._isSafeBackupFile(name)) {
        return;
      }
      if (value is! String) return;
      final dir = Directory('${rootDir.path}${Platform.pathSeparator}$id');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(
        '${dir.path}${Platform.pathSeparator}$name',
      ).writeAsBytesSync(base64Decode(value));
    });
    // loadEntries() returns an unmodifiable list while there is no index yet
    // (exactly the fresh-install case this restore exists for), so copy it
    // before adding restored papers.
    final current = List<PaperEntry>.of(await PaperLibrary.loadEntries());
    final known = current.map((e) => e.id).toSet();
    var added = 0;
    for (final e in restored) {
      if (known.contains(e.id)) continue;
      current.add(e);
      known.add(e.id);
      added++;
    }
    if (added > 0) await PaperLibrary._saveEntries(current);
    return added;
  }
}
