import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/models/paper_document.dart';
import 'package:tutors_desk/services/paper_document_layout.dart';
import 'package:tutors_desk/services/paper_spell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tables', () {
    test('a blank table has the requested grid', () {
      final t = DocTable.blank(2, 3);
      expect(t.rows.length, 2);
      expect(t.columnCount, 3);
    });

    test('rows and columns can be inserted and deleted', () {
      final t = DocTable.blank(2, 2);
      expect(t.insertRow(1).rows.length, 3);
      expect(t.deleteRow(0).rows.length, 1);
      expect(t.insertColumn(0).columnCount, 3);
      expect(t.deleteColumn(1).columnCount, 1);
    });

    test('a table survives a JSON round trip', () {
      final doc = PaperDocument.blank(id: 'tbl1').copyWith(
        paragraphs: [
          DocParagraph(id: 't', table: DocTable.blank(2, 2)),
        ],
      );
      final back = PaperDocument.fromJson(doc.toJson());
      expect(back.tableCount, 1);
      expect(back.paragraphs.single.table!.rows.length, 2);
    });

    test('row height follows the tallest cell', () {
      final short = DocTable.blank(1, 2);
      final long = DocTable([
        [
          DocParagraph(
            id: 'x',
            text: List.generate(40, (i) => 'word$i').join(' '),
          ),
          DocParagraph(id: 'y', text: 'a'),
        ],
      ]);
      final h1 = tableRowHeights(short, 1, 400).single;
      final h2 = tableRowHeights(long, 1, 400).single;
      expect(h2, greaterThan(h1));
    });
  });

  group('page layout', () {
    test('a page break starts a new page', () {
      final doc = PaperDocument.blank(id: 'brk').copyWith(
        paragraphs: [
          DocParagraph(id: 'a', text: 'one'),
          DocParagraph(id: 'b', kind: ParaKind.pageBreak),
          DocParagraph(id: 'c', text: 'two'),
        ],
      );
      final layout = PaperLayout.compute(doc, 1);
      expect(layout.pageCount, 2);
      expect(layout.pageOf(0), 0);
      expect(layout.pageOf(2), 1);
    });

    test('long content flows onto more pages without splitting a block', () {
      final text = List.generate(60, (i) => 'Line $i of the text').join(' ');
      final doc = PaperDocument.blank(id: 'long').copyWith(
        paragraphs: [
          for (var i = 0; i < 40; i++) DocParagraph(id: 'p$i', text: text),
        ],
      );
      final layout = PaperLayout.compute(doc, 1);
      expect(layout.pageCount, greaterThan(1));
      for (final page in layout.pages) {
        for (final item in page) {
          expect(item.top + item.height,
              lessThanOrEqualTo(PaperPage.contentHeightPt + 1));
        }
      }
    });

    test('an empty paper is one page', () {
      final layout = PaperLayout.compute(PaperDocument.blank(id: 'e'), 1);
      expect(layout.pageCount, 1);
    });
  });

  group('spelling', () {
    setUpAll(() async {
      await PaperSpell.load();
    });

    test('correct words are not flagged', () {
      expect(PaperSpell.misspellings('the quick brown fox'), isEmpty);
    });

    test('a misspelled word is flagged with its position', () {
      const text = 'I recieve the mail';
      final ranges = PaperSpell.misspellings(text);
      expect(ranges.length, 1);
      expect(text.substring(ranges.single.$1, ranges.single.$2), 'recieve');
    });

    test('suggestions include the intended word', () {
      expect(PaperSpell.suggestions('teh'), contains('the'));
    });
  });
}
