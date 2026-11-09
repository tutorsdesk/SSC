import 'dart:typed_data';

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

  group('pictures', () {
    final bytes = Uint8List.fromList(
      [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3],
    );

    test('picture JSON keeps bytes, aspect and width', () {
      final img = DocImage(bytes: bytes, aspect: 0.5, widthFraction: 0.35);
      final back = DocImage.fromJson(img.toJson());
      expect(back.bytes, bytes);
      expect(back.aspect, 0.5);
      expect(back.widthFraction, 0.35);
    });

    test('a picture block survives a document round trip and is counted', () {
      final doc = PaperDocument(
        id: 'img',
        title: 'Pictures',
        paragraphs: [
          DocParagraph(
            id: 'pic',
            kind: ParaKind.image,
            image: DocImage(bytes: bytes, aspect: 0.75),
          ),
          _para('After the picture', id: 'txt'),
        ],
      );
      expect(doc.pictureCount, 1);
      final back = PaperDocument.fromJson(doc.toJson());
      expect(back.pictureCount, 1);
      expect(back.paragraphs.first.kind, ParaKind.image);
      expect(back.paragraphs.first.image!.bytes, bytes);
      expect(back.paragraphs.last.text, 'After the picture');
    });

    test('a damaged picture does not stop the document loading', () {
      final back = PaperDocument.fromJson({
        'id': 'x',
        'title': 'T',
        'paragraphs': [
          {'id': 'p', 'kind': 'image', 'text': '', 'image': {'data': ''}},
        ],
      });
      expect(back.paragraphs.single.image, isNotNull);
    });
  });

  group('tables and cells', () {
    test('a blank table has the requested size and editable cells', () {
      final t = DocTable.blank(2, 3);
      expect(t.rowCount, 2);
      expect(t.columnCount, 3);
      for (final row in t.rows) {
        for (final cell in row) {
          expect(cell.text, '');
          expect(cell.id, isNotEmpty);
        }
      }
    });

    test('inserting and deleting rows and columns changes the size', () {
      final t = DocTable.blank(2, 2);
      expect(t.insertRow(1).rowCount, 3);
      expect(t.deleteRow(0).rowCount, 1);
      expect(t.insertColumn(0).columnCount, 3);
      expect(t.deleteColumn(1).columnCount, 1);
    });

    test('a table survives a document round trip with cell text', () {
      final table = DocTable([
        [_para('Name', id: 'c00'), _para('Marks', id: 'c01')],
        [_para('Rahim', id: 'c10'), _para('80', id: 'c11')],
      ]);
      final doc = PaperDocument(
        id: 'tbl',
        title: 'Table',
        paragraphs: [
          DocParagraph(id: 'tb', kind: ParaKind.table, table: table),
        ],
      );
      expect(doc.tableCount, 1);
      final back = PaperDocument.fromJson(doc.toJson());
      final t = back.paragraphs.single.table!;
      expect(t.rowCount, 2);
      expect(t.columnCount, 2);
      expect(t.rows[1][0].text, 'Rahim');
      expect(t.rows[1][1].text, '80');
    });

    test('locateCell finds a cell by its id', () {
      final list = [
        DocParagraph(
          id: 'tb',
          kind: ParaKind.table,
          table: DocTable([
            [_para('a', id: 'c00'), _para('b', id: 'c01')],
            [_para('c', id: 'c10'), _para('d', id: 'c11')],
          ]),
        ),
      ];
      final ref = locateCell(list, 'c11');
      expect(ref, isNotNull);
      expect(ref!.tableId, 'tb');
      expect(ref.row, 1);
      expect(ref.col, 1);
      expect(locateCell(list, 'missing'), isNull);
    });

    test('replaceById edits one cell and leaves the others alone', () {
      final list = [
        DocParagraph(
          id: 'tb',
          kind: ParaKind.table,
          table: DocTable([
            [_para('a', id: 'c00'), _para('b', id: 'c01')],
          ]),
        ),
      ];
      final next = replaceById(list, 'c01', _para('Changed', id: 'c01'));
      final row = next.single.table!.rows.single;
      expect(row[0].text, 'a');
      expect(row[1].text, 'Changed');
      expect(list.single.table!.rows.single[1].text, 'b');
    });

    test('replaceWordEverywhere also changes words inside table cells', () {
      final list = [
        _para('teh start', id: 'p1'),
        DocParagraph(
          id: 'tb',
          kind: ParaKind.table,
          table: DocTable([
            [_para('teh cell', id: 'c00')],
          ]),
        ),
      ];
      final next = replaceWordEverywhere(list, 'teh', 'the');
      expect(next.first.text, 'the start');
      expect(next.last.table!.rows.single.single.text, 'the cell');
    });
  });

  group('header and footer', () {
    test('page header, footer and page numbers survive a round trip', () {
      final doc = PaperDocument(
        id: 'hf',
        title: 'Header test',
        header: const PaperHeader(school: 'Ideal School', exam: 'Half Yearly'),
        pageHeader: 'Class 8 — Mathematics',
        pageFooter: 'Page footer text',
        showPageNumbers: false,
        paragraphs: [_para('Body')],
      );
      final back = PaperDocument.fromJson(doc.toJson());
      expect(back.header.school, 'Ideal School');
      expect(back.header.exam, 'Half Yearly');
      expect(back.pageHeader, 'Class 8 — Mathematics');
      expect(back.pageFooter, 'Page footer text');
      expect(back.showPageNumbers, isFalse);
    });

    test('page numbers are shown unless turned off', () {
      final back = PaperDocument.fromJson({'id': 'x', 'title': 'T'});
      expect(back.showPageNumbers, isTrue);
      expect(back.pageHeader, '');
      expect(back.pageFooter, '');
    });
  });
}
