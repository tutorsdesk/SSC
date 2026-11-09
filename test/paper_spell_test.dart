import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/services/paper_spell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled Bangla list loads and accepts common words', () async {
    await PaperSpell.load();
    expect(PaperSpell.banglaReady, isTrue);
    expect(PaperSpell.isCorrect('বাংলা'), isTrue);
    expect(PaperSpell.misspellings('বই পড়া'), isEmpty);
  });

  test('a Bangla word close to a listed word is suggested', () async {
    await PaperSpell.load();
    expect(PaperSpell.suggestions('বাংল', limit: 50), contains('বাংলা'));
  });

  test('English checking still works next to Bangla', () async {
    await PaperSpell.load();
    final text = 'teh বই';
    final ranges = PaperSpell.misspellings(text);
    expect(ranges.map((r) => text.substring(r.$1, r.$2)), ['teh']);
    expect(PaperSpell.suggestions('teh').first, 'the');
  });
}
