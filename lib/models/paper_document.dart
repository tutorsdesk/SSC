/// Word-style question paper document used by the Paper Editor.
///
/// A document is an ordered list of blocks (paragraphs, questions, tables,
/// pictures and page breaks). Text blocks hold per-character formatting.
/// Documents are immutable: every edit returns a new [PaperDocument], which
/// keeps undo/redo cheap and safe.
///
/// This file is plain Dart (no Flutter imports) so the rules can be tested
/// directly.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

enum ParaKind {
  title,
  heading,
  normal,
  instruction,
  question,
  option,
  pageBreak,
  table,
  image,
}

enum ParaAlign { left, center, right, justify }

enum TextFlag { bold, italic, underline }

/// Option labels for MCQ/option groups, in Bengali.
const List<String> kOptionLabels = [
  'ক',
  'খ',
  'গ',
  'ঘ',
  'ঙ',
  'চ',
  'ছ',
  'জ',
];

const List<String> _bnDigits = [
  '০',
  '১',
  '২',
  '৩',
  '৪',
  '৫',
  '৬',
  '৭',
  '৮',
  '৯',
];

/// 12 → "১২".
String toBanglaNumber(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (final ch in s.split('')) {
    b.write(_bnDigits[int.parse(ch)]);
  }
  return b.toString();
}

int _idSeq = 0;

/// A new unique block id.
String newParaId() {
  _idSeq++;
  return 'p${DateTime.now().microsecondsSinceEpoch}_$_idSeq';
}

/// A new document id that is safe to use as a file name.
String newDocId() {
  _idSeq++;
  return 'd${DateTime.now().microsecondsSinceEpoch}_$_idSeq';
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Look-and-feel defaults for each block kind (sizes in points).
extension ParaKindLook on ParaKind {
  double get basePt => switch (this) {
        ParaKind.title => 20,
        ParaKind.heading => 14,
        ParaKind.instruction => 11.5,
        ParaKind.option => 12,
        _ => 12.5,
      };

  bool get bold => this == ParaKind.title || this == ParaKind.heading;

  bool get italic => this == ParaKind.instruction;

  double get beforePt => switch (this) {
        ParaKind.heading => 16,
        ParaKind.question => 10,
        ParaKind.table => 8,
        ParaKind.image => 8,
        _ => 0,
      };

  double get afterPt => switch (this) {
        ParaKind.title => 10,
        ParaKind.heading => 6,
        ParaKind.option => 2,
        ParaKind.question => 4,
        ParaKind.table => 8,
        ParaKind.image => 8,
        _ => 6,
      };

  /// Kinds that show a number or letter in the left gutter.
  bool get hasGutter => this == ParaKind.question || this == ParaKind.option;

  String get label => switch (this) {
        ParaKind.title => 'Title',
        ParaKind.heading => 'Heading',
        ParaKind.normal => 'Normal',
        ParaKind.instruction => 'Instruction',
        ParaKind.question => 'Question',
        ParaKind.option => 'Option',
        ParaKind.pageBreak => 'Page break',
        ParaKind.table => 'Table',
        ParaKind.image => 'Picture',
      };
}

/// Formatting of one character.
class CharStyle {
  final bool bold;
  final bool italic;
  final bool underline;

  /// Font size in points, or null for the block default.
  final double? size;

  const CharStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.size,
  });

  static const CharStyle plain = CharStyle();

  CharStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    double? size,
    bool clearSize = false,
  }) =>
      CharStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        size: clearSize ? null : (size ?? this.size),
      );

  bool hasFlag(TextFlag flag) => switch (flag) {
        TextFlag.bold => bold,
        TextFlag.italic => italic,
        TextFlag.underline => underline,
      };

  CharStyle withFlag(TextFlag flag, bool on) => switch (flag) {
        TextFlag.bold => copyWith(bold: on),
        TextFlag.italic => copyWith(italic: on),
        TextFlag.underline => copyWith(underline: on),
      };

  @override
  bool operator ==(Object other) =>
      other is CharStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.size == size;

  @override
  int get hashCode => Object.hash(bold, italic, underline, size);

  Map<String, dynamic> toJson() => {
        'b': bold,
        'i': italic,
        'u': underline,
        if (size != null) 's': size,
      };

  factory CharStyle.fromJson(Object? raw) {
    if (raw is! Map) return plain;
    final s = raw['s'];
    return CharStyle(
      bold: raw['b'] == true,
      italic: raw['i'] == true,
      underline: raw['u'] == true,
      size: s is num ? s.toDouble() : null,
    );
  }
}

/// A picture placed in the document. The bytes are already resized and
/// re-encoded, so they are small enough to keep inside the document file.
class DocImage {
  final Uint8List bytes;

  /// Height divided by width of the picture.
  final double aspect;

  /// Share of the text width the picture uses (0.2 – 1.0).
  final double widthFraction;

  const DocImage({
    required this.bytes,
    required this.aspect,
    this.widthFraction = 0.6,
  });

  DocImage copyWith({double? widthFraction}) => DocImage(
        bytes: bytes,
        aspect: aspect,
        widthFraction: widthFraction ?? this.widthFraction,
      );

  Map<String, dynamic> toJson() => {
        'data': base64Encode(bytes),
        'aspect': aspect,
        'w': widthFraction,
      };

  factory DocImage.fromJson(Map<String, dynamic> j) => DocImage(
        bytes: base64Decode(j['data'] as String? ?? ''),
        aspect: (j['aspect'] as num?)?.toDouble() ?? 0.75,
        widthFraction: (j['w'] as num?)?.toDouble() ?? 0.6,
      );
}

/// A grid of cells. Each cell is a text paragraph with its own id, so it can
/// be edited like any other paragraph.
class DocTable {
  final List<List<DocParagraph>> rows;

  DocTable(List<List<DocParagraph>> rows)
      : rows = List.unmodifiable([
          for (final r in rows) List<DocParagraph>.unmodifiable(r),
        ]);

  /// A blank table with [rowCount] rows and [columnCount] columns.
  factory DocTable.blank(int rowCount, int columnCount) => DocTable([
        for (var r = 0; r < rowCount; r++)
          [for (var c = 0; c < columnCount; c++) newCell()],
      ]);

  static DocParagraph newCell() => DocParagraph(id: newParaId());

  int get rowCount => rows.length;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;

  DocTable insertRow(int at) {
    final cols = columnCount < 1 ? 1 : columnCount;
    final next = [...rows]..insert(_clampInt(at, 0, rows.length), [
        for (var c = 0; c < cols; c++) newCell(),
      ]);
    return DocTable(next);
  }

  DocTable deleteRow(int at) {
    if (rows.length <= 1) return this;
    return DocTable([...rows]..removeAt(at));
  }

  DocTable insertColumn(int at) {
    final cols = columnCount;
    return DocTable([
      for (final row in rows)
        [...row]..insert(_clampInt(at, 0, cols), newCell()),
    ]);
  }

  DocTable deleteColumn(int at) {
    if (columnCount <= 1) return this;
    return DocTable([
      for (final row in rows) [...row]..removeAt(at),
    ]);
  }

  DocTable replaceCell(int row, int col, DocParagraph cell) => DocTable([
        for (var r = 0; r < rows.length; r++)
          [
            for (var c = 0; c < rows[r].length; c++)
              (r == row && c == col) ? cell : rows[r][c],
          ],
      ]);

  Map<String, dynamic> toJson() => {
        'rows': [
          for (final r in rows) [for (final c in r) c.toJson()],
        ],
      };

  factory DocTable.fromJson(Map<String, dynamic> j) {
    final raw = (j['rows'] as List?) ?? const [];
    final rows = [
      for (final r in raw)
        [
          for (final c in (r as List))
            DocParagraph.fromJson((c as Map).cast<String, dynamic>()),
        ],
    ];
    if (rows.isEmpty) return DocTable.blank(1, 2);
    return DocTable(rows);
  }
}

/// One block of the document: a text paragraph, a page break, a table or a
/// picture. `styles` has exactly one entry per character of `text`.
class DocParagraph {
  final String id;
  final ParaKind kind;
  final ParaAlign align;
  final String text;
  final List<CharStyle> styles;
  final DocTable? table;
  final DocImage? image;

  DocParagraph({
    required this.id,
    this.kind = ParaKind.normal,
    this.align = ParaAlign.left,
    this.text = '',
    List<CharStyle>? styles,
    this.table,
    this.image,
  }) : styles = List.unmodifiable(
          styles ?? List<CharStyle>.filled(text.length, CharStyle.plain),
        ) {
    assert(this.styles.length == text.length, 'styles must match text');
  }

  DocParagraph copyWith({
    ParaKind? kind,
    ParaAlign? align,
    String? text,
    List<CharStyle>? styles,
    DocTable? table,
    DocImage? image,
  }) {
    return DocParagraph(
      id: id,
      kind: kind ?? this.kind,
      align: align ?? this.align,
      text: text ?? this.text,
      styles: styles ?? (text == null ? this.styles : null),
      table: table ?? this.table,
      image: image ?? this.image,
    );
  }

  /// Applies [change] to the characters in [start, end).
  DocParagraph restyle(
    int start,
    int end,
    CharStyle Function(CharStyle) change,
  ) {
    final s = _clampInt(start, 0, text.length);
    final e = _clampInt(end, s, text.length);
    final next = <CharStyle>[
      for (var i = 0; i < styles.length; i++)
        (i >= s && i < e) ? change(styles[i]) : styles[i],
    ];
    return copyWith(styles: next);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'align': align.name,
        'text': text,
        'styles': [for (final s in styles) s.toJson()],
        if (table != null) 'table': table!.toJson(),
        if (image != null) 'image': image!.toJson(),
      };

  factory DocParagraph.fromJson(Map<String, dynamic> j) {
    final text = j['text'] as String? ?? '';
    final raw = (j['styles'] as List?) ?? const [];
    final styles = <CharStyle>[
      for (var i = 0; i < text.length; i++)
        CharStyle.fromJson(i < raw.length ? raw[i] : null),
    ];
    final tableJson = j['table'];
    final imageJson = j['image'];
    return DocParagraph(
      id: j['id'] as String? ?? newParaId(),
      kind: _enumByName(ParaKind.values, j['kind'], ParaKind.normal),
      align: _enumByName(ParaAlign.values, j['align'], ParaAlign.left),
      text: text,
      styles: styles,
      table: tableJson is Map
          ? DocTable.fromJson(tableJson.cast<String, dynamic>())
          : null,
      image: imageJson is Map
          ? DocImage.fromJson(imageJson.cast<String, dynamic>())
          : null,
    );
  }
}

/// Paper details printed at the top of the first page.
class PaperHeader {
  final String school;
  final String exam;
  final String subject;
  final String time;
  final String marks;

  const PaperHeader({
    this.school = '',
    this.exam = '',
    this.subject = '',
    this.time = '',
    this.marks = '',
  });

  bool get isEmpty =>
      school.trim().isEmpty &&
      exam.trim().isEmpty &&
      subject.trim().isEmpty &&
      time.trim().isEmpty &&
      marks.trim().isEmpty;

  /// Time and marks on one line, e.g. "Time: 2 hours     Marks: 100".
  String get details => [
        if (time.trim().isNotEmpty) 'Time: ${time.trim()}',
        if (marks.trim().isNotEmpty) 'Marks: ${marks.trim()}',
      ].join('     ');

  PaperHeader copyWith({
    String? school,
    String? exam,
    String? subject,
    String? time,
    String? marks,
  }) =>
      PaperHeader(
        school: school ?? this.school,
        exam: exam ?? this.exam,
        subject: subject ?? this.subject,
        time: time ?? this.time,
        marks: marks ?? this.marks,
      );

  Map<String, dynamic> toJson() => {
        'school': school,
        'exam': exam,
        'subject': subject,
        'time': time,
        'marks': marks,
      };

  factory PaperHeader.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const PaperHeader();
    return PaperHeader(
      school: j['school'] as String? ?? '',
      exam: j['exam'] as String? ?? '',
      subject: j['subject'] as String? ?? '',
      time: j['time'] as String? ?? '',
      marks: j['marks'] as String? ?? '',
    );
  }
}

/// Location of a table cell.
class CellRef {
  final String tableId;
  final int row;
  final int col;
  const CellRef(this.tableId, this.row, this.col);
}

/// Block list after replacing the block at [index] with [next].
List<DocParagraph> replaceParagraph(
  List<DocParagraph> list,
  int index,
  List<DocParagraph> next,
) =>
    [...list.sublist(0, index), ...next, ...list.sublist(index + 1)];

/// Finds a block or table cell by id (searching table cells too).
DocParagraph? findParagraph(List<DocParagraph> list, String id) {
  for (final p in list) {
    if (p.id == id) return p;
    final t = p.table;
    if (t != null) {
      for (final row in t.rows) {
        final hit = findParagraph(row, id);
        if (hit != null) return hit;
      }
    }
  }
  return null;
}

/// Where a table cell sits, or null when [cellId] is not a table cell.
CellRef? locateCell(List<DocParagraph> list, String cellId) {
  for (final p in list) {
    final t = p.table;
    if (t == null) continue;
    for (var r = 0; r < t.rows.length; r++) {
      for (var c = 0; c < t.rows[r].length; c++) {
        if (t.rows[r][c].id == cellId) return CellRef(p.id, r, c);
      }
    }
  }
  return null;
}

/// Replaces the block or cell [id] with [next] (same id), anywhere in the
/// tree. Blocks that are not found are left unchanged.
List<DocParagraph> replaceById(
  List<DocParagraph> list,
  String id,
  DocParagraph next,
) {
  return [
    for (final p in list)
      if (p.id == id)
        next
      else if (p.table != null && findParagraph([p], id) != null)
        p.copyWith(
          table: DocTable([
            for (final row in p.table!.rows) replaceById(row, id, next),
          ]),
        )
      else
        p,
  ];
}

/// Paragraphs that replace [old] after the user edits its text.
///
/// Characters typed in the middle inherit the style of the character before
/// them (or [typing], when the user has picked a style for new text). When
/// [split] is true, a newline (Enter, or a pasted line break) splits the
/// paragraph: the first piece keeps [old]'s id and the rest get fresh ids.
/// Table cells pass `split: false` and keep the newline inside the cell.
List<DocParagraph> editParagraphText(
  DocParagraph old,
  String next, {
  CharStyle? typing,
  bool split = true,
}) {
  final before = old.text;
  var prefix = 0;
  final minLen = math.min(before.length, next.length);
  while (prefix < minLen && before[prefix] == next[prefix]) {
    prefix++;
  }
  var suffix = 0;
  final maxSuffix = minLen - prefix;
  while (suffix < maxSuffix &&
      before[before.length - 1 - suffix] == next[next.length - 1 - suffix]) {
    suffix++;
  }
  final insertedLen = next.length - prefix - suffix;
  final CharStyle inherited;
  if (prefix > 0) {
    inherited = old.styles[prefix - 1];
  } else if (old.styles.isNotEmpty) {
    inherited = old.styles[0];
  } else {
    inherited = CharStyle.plain;
  }
  final styles = <CharStyle>[
    ...old.styles.sublist(0, prefix),
    ...List<CharStyle>.filled(insertedLen, typing ?? inherited),
    ...old.styles.sublist(before.length - suffix),
  ];

  final pieces = split ? next.split('\n') : [next];
  if (pieces.length == 1) {
    return [old.copyWith(text: next, styles: styles)];
  }
  final result = <DocParagraph>[];
  var offset = 0;
  for (var i = 0; i < pieces.length; i++) {
    final piece = pieces[i];
    result.add(
      DocParagraph(
        id: i == 0 ? old.id : newParaId(),
        kind: i == 0 ? old.kind : _continuationKind(old.kind),
        align: old.align,
        text: piece,
        styles: styles.sublist(offset, offset + piece.length),
      ),
    );
    offset += piece.length + 1; // skip the newline
  }
  return result;
}

/// Kind for the paragraph that Enter creates after [kind].
ParaKind _continuationKind(ParaKind kind) => switch (kind) {
      ParaKind.question => ParaKind.question,
      ParaKind.option => ParaKind.option,
      _ => ParaKind.normal,
    };

/// Replaces whole-word occurrences of [word] (case-insensitive) with
/// [replacement] in every text block and table cell.
List<DocParagraph> replaceWordEverywhere(
  List<DocParagraph> list,
  String word,
  String replacement,
) {
  final pattern = RegExp(
    '(?<![A-Za-z\\u0980-\\u09FF])${RegExp.escape(word)}'
    '(?![A-Za-z\\u0980-\\u09FF])',
    caseSensitive: false,
  );
  return [
    for (final p in list)
      if (p.table != null)
        p.copyWith(
          table: DocTable([
            for (final row in p.table!.rows)
              replaceWordEverywhere(row, word, replacement),
          ]),
        )
      else if (p.kind != ParaKind.image && pattern.hasMatch(p.text))
        _replaceInText(p, pattern, replacement)
      else
        p,
  ];
}

DocParagraph _replaceInText(
  DocParagraph p,
  RegExp pattern,
  String replacement,
) {
  final text = StringBuffer();
  final styles = <CharStyle>[];
  var last = 0;
  for (final m in pattern.allMatches(p.text)) {
    text.write(p.text.substring(last, m.start));
    styles.addAll(p.styles.sublist(last, m.start));
    text.write(replacement);
    final style = p.styles[m.start];
    styles.addAll(List<CharStyle>.filled(replacement.length, style));
    last = m.end;
  }
  text.write(p.text.substring(last));
  styles.addAll(p.styles.sublist(last));
  return p.copyWith(text: text.toString(), styles: styles);
}

class PaperDocument {
  final String id;
  final String title;
  final PaperHeader header;

  /// Small text printed at the top of every page (optional).
  final String pageHeader;

  /// Small text printed at the bottom of every page (optional).
  final String pageFooter;
  final bool showPageNumbers;
  final List<DocParagraph> paragraphs;
  final DateTime updatedAt;

  PaperDocument({
    required this.id,
    required this.title,
    this.header = const PaperHeader(),
    this.pageHeader = '',
    this.pageFooter = '',
    this.showPageNumbers = true,
    required List<DocParagraph> paragraphs,
    DateTime? updatedAt,
  })  : paragraphs = List.unmodifiable(paragraphs),
        updatedAt = updatedAt ?? DateTime.now();

  factory PaperDocument.blank({required String id, String? title}) =>
      PaperDocument(
        id: id,
        title: title ?? 'Untitled paper',
        paragraphs: [
          DocParagraph(
            id: newParaId(),
            kind: ParaKind.title,
            align: ParaAlign.center,
            text: 'Model Test',
          ),
          DocParagraph(
            id: newParaId(),
            kind: ParaKind.instruction,
            text: 'Answer all the questions.',
          ),
          DocParagraph(
            id: newParaId(),
            kind: ParaKind.heading,
            text: 'Section A',
          ),
          DocParagraph(id: newParaId(), kind: ParaKind.question),
        ],
      );

  PaperDocument copyWith({
    String? title,
    PaperHeader? header,
    String? pageHeader,
    String? pageFooter,
    bool? showPageNumbers,
    List<DocParagraph>? paragraphs,
    DateTime? updatedAt,
  }) =>
      PaperDocument(
        id: id,
        title: title ?? this.title,
        header: header ?? this.header,
        pageHeader: pageHeader ?? this.pageHeader,
        pageFooter: pageFooter ?? this.pageFooter,
        showPageNumbers: showPageNumbers ?? this.showPageNumbers,
        paragraphs: paragraphs ?? this.paragraphs,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  int indexOf(String paragraphId) =>
      paragraphs.indexWhere((p) => p.id == paragraphId);

  /// Question number (1-based) for question blocks, null otherwise.
  List<int?> get questionNumbers {
    final out = <int?>[];
    var n = 0;
    for (final p in paragraphs) {
      if (p.kind == ParaKind.question) {
        n++;
        out.add(n);
      } else {
        out.add(null);
      }
    }
    return out;
  }

  /// Option label (ক, খ, …) for option blocks, null otherwise.
  /// Labels restart after any block that is not an option.
  List<String?> get optionLabels {
    final out = <String?>[];
    var k = 0;
    for (final p in paragraphs) {
      if (p.kind == ParaKind.option) {
        out.add(kOptionLabels[k % kOptionLabels.length]);
        k++;
      } else {
        out.add(null);
        k = 0;
      }
    }
    return out;
  }

  /// Every text block, including table cells.
  Iterable<DocParagraph> get allTextBlocks sync* {
    Iterable<DocParagraph> walk(List<DocParagraph> list) sync* {
      for (final p in list) {
        final t = p.table;
        if (t != null) {
          for (final row in t.rows) {
            yield* walk(row);
          }
        } else if (p.kind != ParaKind.pageBreak && p.kind != ParaKind.image) {
          yield p;
        }
      }
    }

    yield* walk(paragraphs);
  }

  int get wordCount {
    var words = 0;
    for (final p in allTextBlocks) {
      final t = p.text.trim();
      if (t.isEmpty) continue;
      words += t.split(RegExp(r'\s+')).length;
    }
    return words;
  }

  int get questionCount =>
      paragraphs.where((p) => p.kind == ParaKind.question).length;

  int get pageBreakCount =>
      paragraphs.where((p) => p.kind == ParaKind.pageBreak).length;

  int get tableCount => paragraphs.where((p) => p.table != null).length;

  int get pictureCount => paragraphs.where((p) => p.image != null).length;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'title': title,
        'header': header.toJson(),
        'pageHeader': pageHeader,
        'pageFooter': pageFooter,
        'showPageNumbers': showPageNumbers,
        'updatedAt': updatedAt.toIso8601String(),
        'paragraphs': [for (final p in paragraphs) p.toJson()],
      };

  factory PaperDocument.fromJson(Map<String, dynamic> j) {
    final raw = (j['paragraphs'] as List?) ?? const [];
    return PaperDocument(
      id: j['id'] as String? ?? newDocId(),
      title: j['title'] as String? ?? 'Untitled paper',
      header: PaperHeader.fromJson(
        (j['header'] as Map?)?.cast<String, dynamic>(),
      ),
      pageHeader: j['pageHeader'] as String? ?? '',
      pageFooter: j['pageFooter'] as String? ?? '',
      showPageNumbers: j['showPageNumbers'] != false,
      paragraphs: [
        for (final p in raw)
          DocParagraph.fromJson((p as Map).cast<String, dynamic>()),
      ],
      updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    );
  }
}
