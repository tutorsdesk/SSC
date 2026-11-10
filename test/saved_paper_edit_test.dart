import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/models/paper_document.dart';
import 'package:tutors_desk/services/paper_library.dart';
import 'package:tutors_desk/services/paper_to_document.dart';

void main() {
  test('a saved paper becomes an editable copy with questions and options', () {
    final paper = SavedPaper(
      id: 'Paper 1/2',
      title: 'Physics Test',
      subject: 'Physics',
      subjectId: 'physics',
      subjectCode: '১০৯',
      setCode: 'ক',
      total: 2,
      key: const [0, 1],
      questions: const [
        SavedQuestion(text: 'Q one', options: ['a', 'b', 'c', 'd'], answer: 0),
        SavedQuestion(text: 'Q two', options: ['a', 'b'], answer: 1),
      ],
      createdAt: DateTime(2026),
    );
    final doc = SavedPaperEditing.documentFrom(paper);
    expect(doc.id, 'saved_Paper_1_2');
    expect(doc.title, 'Physics Test');
    expect(doc.header.subject, 'Physics');
    expect(doc.header.marks, '2');
    expect(
      doc.paragraphs.map((p) => p.kind).toList(),
      [
        ParaKind.title,
        ParaKind.question,
        ParaKind.option,
        ParaKind.option,
        ParaKind.option,
        ParaKind.option,
        ParaKind.question,
        ParaKind.option,
        ParaKind.option,
      ],
    );
    expect(doc.paragraphs[1].text, 'Q one');
    expect(doc.paragraphs.last.text, 'b');
  });
}
