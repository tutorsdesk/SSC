/// Word-style question paper document used by the Paper Editor.
///
/// A document is an ordered list of paragraphs. Each paragraph has a kind
/// (title, heading, question, option …), an alignment and per-character
/// formatting. Documents are immutable: every edit returns a new
/// [PaperDocument], which keeps undo/redo cheap and safe.
///
/// This file is plain Dart (no Flutter imports) so the rules can be tested
/// directly.
library;

import 'dart:math' as math;

enum ParaKind {
  title,
  heading,
  normal,
  instruction,
  question,
  option,
  pageBreak,
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

/// A new unique paragraph id.
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

/// Look-and-feel defaults for each paragraph kind (sizes in points).
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
        _ => 0,
      };

  double get afterPt => switch (this) {
        ParaKind.title => 10,
        ParaKind.heading => 6,
        ParaKind.option => 2,
        ParaKind.question => 4,
        _ => 6,
      };

  String get label => switch (this) {
        ParaKind.title => 'Title',
        ParaKind.heading => 'Heading',
        ParaKind.normal => 'Normal',
        ParaKind.instruction => 'Instruction',
        ParaKind.question => 'Question',
        ParaKind.option => 'Option',
        ParaKind.pageBreak => 'Page break',
      };
}

/// Formatting of one character.
class CharStyle {
  final bool bold;
  final bool italic;
  final bool underline;

  /// Font size in points, or null for the paragraph default.
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

/// One paragraph. `styles` has exactly one entry per character of `text`.
class DocParagraph {
  final String id;
  final ParaKind kind;
  final ParaAlign align;
  final String text;
  final List<CharStyle> styles;

  DocParagraph({
    required this.id,
    this.kind = ParaKind.normal,
    this.align = ParaAlign.left,
    this.text = '',
    List<CharStyle>? styles,
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
  }) {
    return DocParagraph(
      id: id,
      kind: kind ?? this.kind,
      align: align ?? this.align,
      text: text ?? this.text,
      styles: styles ?? (text == null ? this.styles : null),
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
      };

  factory DocParagraph.fromJson(Map<String, dynamic> j) {
    final text = j['text'] as String? ?? '';
    final raw = (j['styles'] as List?) ?? const [];
    final styles = <CharStyle>[
      for (var i = 0; i < text.length; i++)
        CharStyle.fromJson(i < raw.length ? raw[i] : null),
    ];
    return DocParagraph(
      id: j['id'] as String? ?? newParaId(),
      kind: _enumByName(ParaKind.values, j['kind'], ParaKind.normal),
      align: _enumByName(ParaAlign.values, j['align'], ParaAlign.left),
      text: text,
      styles: styles,
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

/// Paragraph list after replacing the paragraph at [index] with [next].
List<DocParagraph> replaceParagraph(
  List<DocParagraph> list,
  int index,
  List<DocParagraph> next,
) =>
    [...list.sublist(0, index), ...next, ...list.sublist(index + 1)];

/// Paragraphs that replace [old] after the user edits its text.
///
/// Characters typed in the middle inherit the style of the character before
/// them (or [typing], when the user has picked a style for new text). A
/// newline (Enter, or a pasted line break) splits the paragraph: the first
/// piece keeps [old]'s id and the rest get fresh ids.
List<DocParagraph> editParagraphText(
  DocParagraph old,
  String next, {
  CharStyle? typing,
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

  final pieces = next.split('\n');
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

  /// Question number (1-based) for question paragraphs, null otherwise.
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

  /// Option label (ক, খ, …) for option paragraphs, null otherwise.
  /// Labels restart after any paragraph that is not an option.
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

  int get wordCount {
    var words = 0;
    for (final p in paragraphs) {
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
