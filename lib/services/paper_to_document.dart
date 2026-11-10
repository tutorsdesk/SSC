import '../models/paper_document.dart';
import 'paper_document_store.dart';
import 'paper_library.dart';

/// Editable copies of saved papers.
///
/// Editing works on a separate copy in the paper editor. The saved paper and
/// its answer key (used by the OMR scanner) are never changed by editing.
abstract final class SavedPaperEditing {
  /// Stable document id for the editable copy of [paperId].
  static String docIdFor(String paperId) {
    final safe = paperId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'saved_$safe';
  }

  /// The question text of [paper] as a new, unsaved document.
  static PaperDocument documentFrom(SavedPaper paper) {
    final paragraphs = <DocParagraph>[
      DocParagraph(id: newParaId(), kind: ParaKind.title, text: paper.title),
    ];
    for (final q in paper.questions) {
      paragraphs.add(
        DocParagraph(id: newParaId(), kind: ParaKind.question, text: q.text),
      );
      for (final option in q.options) {
        paragraphs.add(
          DocParagraph(id: newParaId(), kind: ParaKind.option, text: option),
        );
      }
    }
    return PaperDocument(
      id: docIdFor(paper.id),
      title: paper.title,
      header: PaperHeader(subject: paper.subject, marks: '${paper.total}'),
      paragraphs: paragraphs,
    );
  }

  /// The existing editable copy of [paper], or a new one saved to the
  /// editor's document list. Reopening a paper edits the same copy.
  static Future<PaperDocument> openCopy(SavedPaper paper) async {
    final id = docIdFor(paper.id);
    final existing =
        (await PaperDocumentStore.list()).where((doc) => doc.id == id).toList();
    if (existing.isNotEmpty) return existing.first;
    final doc = documentFrom(paper);
    await PaperDocumentStore.save(doc);
    return doc;
  }
}
