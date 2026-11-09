import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/models/paper_document.dart';

DocParagraph _para(
  String text, {
  ParaKind kind = ParaKind.normal,
  String id = 'a',
}) =>
    DocParagraph(id: id, kind: kind, text: text);

void main() {
  group('editParagraphText', () {
    test('typing in the middle keeps the surrounding styles', () {
      final bold = const CharStyle(bold: true);
      final old = DocParagraph(
        id: 'a',
        text: 'abcd',
        styles: [bold, bold, CharStyle.plain, CharStyle.plain],
      );
      final out = editParagraphText(old, 'abXcd');
      expect(out.length, 1);
      expect(out.single.id, 'a');
      expect(out.single.text, 'abXcd');
      // X inherits the style of the character before it (bold).
      expect(out.single.styles[2], bold);
      expect(out.single.styles[3], CharStyle.plain);
    });

    test('a pending style is applied to typed characters', () {
      final old = _para('ab');
      final out = editParagraphText(
        old,
        'abc',
        typing: const CharStyle(underline: true),
      );
      expect(out.single.styles[2].underline, isTrue);
      expect(out.single.styles[0].underline, isFalse);
    });

    test('Enter splits a question and keeps it a question', () {
      final old = DocParagraph(
        id: 'q1',
        kind: ParaKind.question,
        text: 'Hello world',
      );
      final out = editParagraphText(old, 'Hello\n world');
      expect(out.length, 2);
      expect(out[0].id, 'q1');
      expect(out[0].text, 'Hello');
      expect(out[1].text, ' world');
      expect(out[1].kind, ParaKind.question);
      expect(out[1].id, isNot('q1'));
    });

    test('Enter after a heading gives a normal paragraph', () {
      final old = _para('Section A', kind: ParaKind.heading, id: 'h');
      final out = editParagraphText(old, 'Section A\n');
      expect(out.length, 2);
      expect(out[1].kind, ParaKind.normal);
      expect(out[1].text, '');
    });

    test('deleting text removes its styles', () {
      final old = DocParagraph(
        id: 'a',
        text: 'xyz',
        styles: [
          CharStyle.plain,
          const CharStyle(italic: true),
          CharStyle.plain,
        ],
      );
      final out = editParagraphText(old, 'xz').single;
      expect(out.text, 'xz');
      expect(out.styles.length, 2);
      expect(out.styles.every((s) => !s.italic), isTrue);
    });
  });

  group('numbering', () {
    test('questions are numbered in order, other kinds are not', () {
      final doc = PaperDocument(
        id: 'd',
        title: 't',
        paragraphs: [
          _para('Title', kind: ParaKind.title, id: '1'),
          _para('Q', kind: ParaKind.question, id: '2'),
          _para('Note', id: '3'),
          _para('Q', kind: ParaKind.question, id: '4'),
        ],
      );
      expect(doc.questionNumbers, [null, 1, null, 2]);
      expect(doc.questionCount, 2);
    });

    test('option labels restart after a non-option paragraph', () {
      final doc = PaperDocument(
        id: 'd',
        title: 't',
        paragraphs: [
          _para('o1', kind: ParaKind.option, id: '1'),
          _para('o2', kind: ParaKind.option, id: '2'),
          _para('Q', kind: ParaKind.question, id: '3'),
          _para('o3', kind: ParaKind.option, id: '4'),
        ],
      );
      expect(doc.optionLabels, ['ক', 'খ', null, 'ক']);
    });

    test('Bengali digits', () {
      expect(toBanglaNumber(0), '০');
      expect(toBanglaNumber(12), '১২');
      expect(toBanglaNumber(305), '৩০৫');
    });
  });

  group('restyle', () {
    test('changes only the selected range', () {
      final p = _para('abcd');
      final out = p.restyle(1, 3, (s) => s.copyWith(bold: true));
      expect(out.styles[0].bold, isFalse);
      expect(out.styles[1].bold, isTrue);
      expect(out.styles[2].bold, isTrue);
      expect(out.styles[3].bold, isFalse);
      expect(out.text, 'abcd');
    });
  });

  group('JSON round trip', () {
    test('keeps paragraphs, formatting and header', () {
      final doc = PaperDocument(
        id: 'd1',
        title: 'Model test',
        header: const PaperHeader(school: 'School', marks: '100'),
        pageFooter: 'Good luck',
        paragraphs: [
          DocParagraph(
            id: 'p1',
            kind: ParaKind.question,
            align: ParaAlign.justify,
            text: 'Bold',
            styles: [
              const CharStyle(bold: true, size: 14),
              const CharStyle(bold: true, size: 14),
              const CharStyle(bold: true, size: 14),
              const CharStyle(bold: true, size: 14),
            ],
          ),
        ],
      );
      final back = PaperDocument.fromJson(doc.toJson());
      expect(back.id, 'd1');
      expect(back.title, 'Model test');
      expect(back.header.school, 'School');
      expect(back.pageFooter, 'Good luck');
      expect(back.paragraphs.single.kind, ParaKind.question);
      expect(back.paragraphs.single.align, ParaAlign.justify);
      expect(back.paragraphs.single.styles.first.bold, isTrue);
      expect(back.paragraphs.single.styles.first.size, 14);
    });

    test('a damaged paragraph falls back to defaults', () {
      final back = PaperDocument.fromJson({
        'id': 'x',
        'title': 'T',
        'paragraphs': [
          {'id': 'p', 'kind': 'unknown', 'text': 'hi'},
        ],
      });
      expect(back.paragraphs.single.kind, ParaKind.normal);
      expect(back.paragraphs.single.styles.length, 2);
    });
  });
}
