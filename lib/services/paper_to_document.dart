import 'dart:async';

import '../models/paper_document.dart';
import 'local_diagnostics.dart';
import 'paper_document_render.dart';
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

  static Future<void> _publishChain = Future.value();

  /// Makes the saved paper that [doc] is a copy of show [doc]'s pages.
  /// The answer key is not changed. Calls run one after another.
  static Future<void> publishPages(PaperDocument doc) {
    final run = _publishChain.then((_) => _publish(doc));
    _publishChain = run.catchError((_) {});
    return run;
  }

  /// Number of pages written by the last successful [publishPages], or 0 when
  /// the last call found no saved paper for the document.
  static int lastPublishedPages = 0;

  static Future<void> _publish(PaperDocument doc) async {
    try {
      final entries = (await PaperLibrary.loadEntries())
          .where((e) => e.kind == 'saved')
          .toList();
      for (final e in entries) {
        if (docIdFor(e.id) != doc.id) continue;
        final pages = await PaperDocumentRender.renderPages(doc);
        await PaperLibrary.replaceSavedPages(e.id, pages);
        lastPublishedPages = pages.length;
        return;
      }
      lastPublishedPages = 0;
      unawaited(LocalDiagnostics.record(
        StateError('No saved paper matches the edited copy ${doc.id}'),
        StackTrace.current,
        scope: 'saved_paper',
      ));
    } catch (error, stack) {
      lastPublishedPages = 0;
      unawaited(LocalDiagnostics.record(error, stack, scope: 'saved_paper'));
      rethrow;
    }
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
