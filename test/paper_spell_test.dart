import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/services/paper_spell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled Bangla list loads and accepts common words', () async {
    await PaperSpell.load();
    expect(PaperSpell.banglaReady, isTrue);
    expect(PaperSpell.isCorrect('বাংলা'), isTrue);
    expect(PaperSpell.misspellings('বই বাংলা করা'), isEmpty);
  });

  test('a Bangla word with anusvara is one token and is checked', () async {
    await PaperSpell.load();
    expect(PaperSpell.isBangla('বাংল'), isTrue);
    expect(PaperSpell.suggestions('বাংল', limit: 50), contains('বাংলা'));
  });

  test('decomposed Bengali letters match the composed list entry', () async {
    await PaperSpell.load();
    const composed = 'অজপাড়া'; // listed, uses composed ড়
    final decomposed = composed.replaceAll('\u09DC', '\u09A1\u09BC');
    expect(decomposed, isNot(composed));
    expect(PaperSpell.isCorrect(decomposed), isTrue);
  });

  test('English checking still works next to Bangla', () async {
    await PaperSpell.load();
    const text = 'teh বই';
    final ranges = PaperSpell.misspellings(text);
    expect(ranges.map((r) => text.substring(r.$1, r.$2)), ['teh']);
    expect(PaperSpell.suggestions('teh').first, 'the');
  });
}
