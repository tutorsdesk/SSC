import 'package:flutter/services.dart';

/// Spell-check for the paper editor, English and Bangla.
///
/// The English word list is bundled as `assets/dictionary/en_words.txt`
/// (SCOWL word lists, see `LICENSE-SCOWL.txt`). The Bangla list is optional:
/// `assets/dictionary/bn_words.txt`, one correctly spelled word per line. When
/// it is not bundled, Bangla words count as correct, so nothing is flagged
/// wrongly. Acronyms, contractions and single letters are never flagged.
abstract final class PaperSpell {
  static const String assetPath = 'assets/dictionary/en_words.txt';
  static const String banglaAssetPath = 'assets/dictionary/bn_words.txt';

  /// Latin words, plus runs of Bengali letters and vowel signs.
  static final RegExp _token = RegExp(
    r"[A-Za-z]+(?:['’][A-Za-z]+)*|"
    r"[\u0980-\u0983\u0985-\u09B9\u09BC-\u09CE\u09D7\u09DC\u09DD\u09DF-\u09E3]+",
  );
  static final RegExp _plain = RegExp(r'^[a-z]+$');
  static final RegExp _bengaliWord = RegExp(
    r'^[\u0980-\u0983\u0985-\u09B9\u09BC-\u09CE\u09D7\u09DC\u09DD\u09DF-\u09E3]+$',
  );

  static Set<String>? _words;
  static Set<String>? _banglaWords;
  static Future<void>? _loading;

  /// True once the English word list is loaded.
  static bool get isReady => _words != null;

  /// True when a Bangla word list is bundled and loaded.
  static bool get banglaReady => _banglaWords != null;

  /// True if [word] is written in Bengali letters.
  static bool isBangla(String word) => _bengaliWord.hasMatch(word);

  /// Loads the word lists once. Safe to call repeatedly.
  static Future<void> load() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    _words = _parse(await rootBundle.loadString(assetPath));
    try {
      _banglaWords = _parse(await rootBundle.loadString(banglaAssetPath));
    } catch (_) {
      // No Bangla list bundled: Bangla text simply is not checked.
      _banglaWords = null;
    }
  }

  static Set<String> _parse(String raw) {
    final words = <String>{};
    for (final line in raw.split('\n')) {
      final w = line.trim();
      if (w.isNotEmpty) words.add(w);
    }
    return words;
  }

  /// True if [word] is a known word. Words that cannot be checked
  /// (no list loaded, non-Latin, very short, acronyms, contractions) count as
  /// correct.
  static bool isCorrect(String word) {
    if (word.length < 2) return true;
    if (isBangla(word)) {
      final bn = _banglaWords;
      return bn == null || bn.contains(composeBangla(word));
    }
    final words = _words;
    if (words == null) return true;
    if (word.contains("'") || word.contains('’')) return true;
    if (word == word.toUpperCase()) return true; // acronym such as "MCQ"
    final w = word.toLowerCase();
    if (!_plain.hasMatch(w)) return true;
    return words.contains(w);
  }

  /// Ranges (start, end exclusive) of misspelled words in [text].
  static List<(int, int)> misspellings(String text) {
    if ((_words == null && _banglaWords == null) || text.isEmpty) {
      return const [];
    }
    final out = <(int, int)>[];
    for (final m in _token.allMatches(text)) {
      if (!isCorrect(m.group(0)!)) out.add((m.start, m.end));
    }
    return out;
  }

  /// Up to [limit] close spellings of [word], nearest first. A swapped pair
  /// of letters ("teh" for "the") counts as one edit, and words with the same
  /// letters rank above other words at the same distance.
  static List<String> suggestions(String word, {int limit = 5}) {
    if (isBangla(word)) {
      final bn = _banglaWords;
      if (bn == null) return const [];
      return _nearest(composeBangla(word), bn, limit);
    }
    final words = _words;
    if (words == null) return const [];
    final target = word.toLowerCase();
    if (!_plain.hasMatch(target)) return const [];
    return _nearest(target, words, limit);
  }

  /// Bengali keyboards often type decomposed letters (ড + nukta, ে + া).
  /// The word list uses composed letters, so input is composed before lookup.
  static String composeBangla(String w) => w
      .replaceAll('\u09A1\u09BC', '\u09DC')
      .replaceAll('\u09A2\u09BC', '\u09DD')
      .replaceAll('\u09AF\u09BC', '\u09DF')
      .replaceAll('\u09C7\u09BE', '\u09CB')
      .replaceAll('\u09C7\u09D7', '\u09CC');

  static List<String> _nearest(
    String target,
    Iterable<String> candidates,
    int limit,
  ) {
    final letters = _sortedLetters(target);
    final found = <(int, int, String)>[];
    for (final candidate in candidates) {
      if ((candidate.length - target.length).abs() > 2) continue;
      final d = _distance(target, candidate, 2);
      if (d > 2) continue;
      final sameLetters = _sortedLetters(candidate) == letters ? 0 : 1;
      found.add((d, sameLetters, candidate));
    }
    found.sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    });
    return [for (final f in found.take(limit)) f.$3];
  }

  static String _sortedLetters(String w) {
    final chars = w.split('')..sort();
    return chars.join();
  }

  /// Optimal string alignment distance (Levenshtein plus adjacent swaps),
  /// stopping early once every cell in a row exceeds [max].
  static int _distance(String a, String b, int max) {
    if (a == b) return 0;
    final n = a.length;
    final m = b.length;
    var prev2 = List<int>.filled(m + 1, 0);
    var prev = List<int>.generate(m + 1, (j) => j);
    for (var i = 1; i <= n; i++) {
      final cur = List<int>.filled(m + 1, 0);
      cur[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= m; j++) {
        final same = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1);
        var v = prev[j - 1] + (same ? 0 : 1);
        if (prev[j] + 1 < v) v = prev[j] + 1;
        if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
        if (i > 1 &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1) &&
            prev2[j - 2] + 1 < v) {
          v = prev2[j - 2] + 1;
        }
        cur[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > max) return max + 1;
      prev2 = prev;
      prev = cur;
    }
    return prev[m];
  }
}
