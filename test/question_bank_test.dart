import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/data/questions_data.dart';

import 'support/bank_fixture.dart';

/// Verification gate for the Dart -> JSON migration
/// (docs/question-bank-migration.md, Step 1).
///
/// These are the checks the plan promised: the export must contain exactly
/// the questions the Dart source used to, with nothing dropped or mangled.
void main() {
  setUpAll(BankFixture.ensureLoaded);

  group('Export integrity', () {
    test('the bank holds exactly 6,178 questions', () {
      expect(allMCQs.length, 3500, reason: 'MCQ count changed');
      expect(allSAQs.length, 1120, reason: 'SAQ count changed');
      expect(allCQs.length, 659, reason: 'CQ count changed');
      expect(allMCQs.length + allSAQs.length + allCQs.length, 6178);
    });

    test('the manifest agrees with the files on disk', () {
      final manifest =
          json.decode(File('assets/questions/manifest.json').readAsStringSync())
              as Map<String, dynamic>;

      var counted = 0;
      for (final name in (manifest['files'] as List).cast<String>()) {
        final file = File('assets/questions/$name');
        expect(file.existsSync(), isTrue, reason: '$name is missing');
        final rows = json.decode(file.readAsStringSync()) as List;
        expect(
          rows.length,
          manifest['counts'][name],
          reason: '$name count disagrees with the manifest',
        );
        counted += rows.length;
      }
      expect(counted, manifest['total']);
      expect(counted, 6178);
    });

    test('every id is unique across the whole bank', () {
      final ids = <String>{};
      for (final id in [
        ...allMCQs.map((q) => q.id),
        ...allSAQs.map((q) => q.id),
        ...allCQs.map((q) => q.id),
      ]) {
        expect(ids.add(id), isTrue, reason: 'duplicate id $id');
      }
      expect(ids.length, 6178);
    });

    test('no question lost its text, subject or chapter', () {
      for (final q in allMCQs) {
        expect(q.questionText.trim(), isNotEmpty, reason: q.id);
        expect(q.subjectId.trim(), isNotEmpty, reason: q.id);
        expect(q.chapter.trim(), isNotEmpty, reason: q.id);
      }
      for (final q in allSAQs) {
        expect(q.questionText.trim(), isNotEmpty, reason: q.id);
        expect(q.answer.trim(), isNotEmpty, reason: q.id);
      }
      for (final q in allCQs) {
        expect(q.stem.trim(), isNotEmpty, reason: q.id);
        expect(q.questionK.trim(), isNotEmpty, reason: q.id);
        expect(q.questionKh.trim(), isNotEmpty, reason: q.id);
        // questionGh is deliberately blank on the three-part maths CQs.
      }
    });

    test('every MCQ keeps a valid answer key', () {
      for (final q in allMCQs) {
        expect(q.options, isNotEmpty, reason: q.id);
        expect(q.correctIndex, greaterThanOrEqualTo(0), reason: q.id);
        expect(q.correctIndex, lessThan(q.options.length), reason: q.id);
      }
    });

    test('CQ mark schemes are preserved, including the maths 2/4/4 split', () {
      // Most CQs are the standard ক/খ/গ/ঘ = 1/2/3/4. General maths uses a
      // three-part 2/4/4 scheme, and that difference must survive the export.
      final schemes = allCQs.map((q) => q.marks.join('/')).toSet();
      expect(schemes, contains('1/2/3/4'));
      expect(schemes, contains('2/4/4'));
      expect(
        allCQs.where((q) => q.marks.join('/') == '2/4/4').length,
        170,
        reason: 'the general_math CQ mark scheme changed',
      );
      for (final q in allCQs) {
        expect(q.marks, isNotEmpty, reason: q.id);
      }
    });

    test('structured figures survived the round trip', () {
      final withFigures = [
        ...allMCQs.where((q) => q.figure != null).map((q) => q.figure!),
        ...allCQs.where((q) => q.figure != null).map((q) => q.figure!),
      ];

      for (final f in withFigures) {
        expect(f.headers, isNotEmpty);
      }
      expect(withFigures.where((f) => f.rows.isNotEmpty), isNotEmpty);
      expect(withFigures.where((f) => f.values.isNotEmpty), isNotEmpty);
      expect(withFigures.where((f) => f.rightAngleAt != null), isNotEmpty);
    });

    test('sources are preserved, not flattened to the default', () {
      final sources = allMCQs.map((q) => q.source).toSet();
      expect(sources, contains(QuestionSource.board));
      expect(
        sources.length,
        greaterThan(1),
        reason: 'every question came back as the same source',
      );
      expect(allMCQs.where((q) => q.sourceLabel != null), isNotEmpty);
    });

    test('Bengali text is intact, not mojibake', () {
      final bengali = RegExp(r'[\u0980-\u09FF]');
      final sample = allMCQs.take(500);
      expect(
        sample.where((q) => bengali.hasMatch(q.questionText)).length,
        greaterThan(400),
        reason: 'Bengali characters did not survive the export',
      );
      for (final q in allMCQs.take(2000)) {
        expect(q.questionText.contains('\uFFFD'), isFalse, reason: q.id);
      }
    });
  });

  group('No question data left in Dart', () {
    test('the giant per-subject source files are gone', () {
      const removed = <String>[
        'lib/data/physics/physics_mcqs.dart',
        'lib/data/chemistry/chemistry_mcqs.dart',
        'lib/data/biology/biology_mcqs.dart',
        'lib/data/general_math/general_math_mcqs.dart',
        'lib/data/ict/ict_mcqs.dart',
        'lib/data/bangla_1st/bangla_1st_mcqs.dart',
        'lib/data/bangla_2nd/bangla_2nd_grammar_mcqs.dart',
        'lib/data/bgs/bgs_mcqs.dart',
      ];
      for (final path in removed) {
        expect(
          File(path).existsSync(),
          isFalse,
          reason: '$path should have been migrated to JSON',
        );
      }
    });

    test('questions_data.dart is now small', () {
      final lines = File(
        'lib/data/questions_data.dart',
      ).readAsLinesSync().length;
      expect(
        lines,
        lessThan(200),
        reason: 'it used to be 7,108 lines; the bank should be in JSON',
      );
    });
  });
}
