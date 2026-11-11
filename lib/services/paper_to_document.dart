import 'dart:async';

import '../models/paper_document.dart';
import 'paper_composer.dart';
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

  /// The whole composed paper as an editable document: every MCQ (with its
  /// options), short, creative, literature, written and English section.
  static PaperDocument fullDocument({
    required String title,
    required String subject,
    required String marks,
    required ComposedPaper paper,
  }) {
    final out = <DocParagraph>[
      DocParagraph(id: newParaId(), kind: ParaKind.title, text: title),
    ];
    void add(ParaKind kind, String text) {
      if (text.trim().isEmpty) return;
      out.add(DocParagraph(id: newParaId(), kind: kind, text: text));
    }

    void labelled(List<(String, String)> parts) {
      const labels = ['ক', 'খ', 'গ', 'ঘ'];
      var i = 0;
      for (final (_, text) in parts) {
        if (text.trim().isEmpty) continue;
        add(ParaKind.normal, '${labels[i % labels.length]}) $text');
        i++;
      }
    }

    if (paper.mcqs.isNotEmpty) {
      add(ParaKind.heading, 'বহুনির্বাচনী প্রশ্ন');
      for (final q in paper.mcqs) {
        add(ParaKind.question, q.questionText);
        for (final option in q.options) {
          add(ParaKind.option, option);
        }
      }
    }
    if (paper.saqs.isNotEmpty) {
      add(ParaKind.heading, 'সংক্ষিপ্ত-উত্তর প্রশ্ন');
      for (final q in paper.saqs) {
        add(ParaKind.question, q.questionText);
      }
    }
    if (paper.cqs.isNotEmpty) {
      add(ParaKind.heading, 'সৃজনশীল প্রশ্ন');
      for (final q in paper.cqs) {
        add(ParaKind.question, q.stem);
        labelled([
          ('k', q.questionK),
          ('kh', q.questionKh),
          ('g', q.questionG),
          ('gh', q.questionGh),
        ]);
      }
    }
    if (paper.literature.isNotEmpty) {
      add(ParaKind.heading, 'সাহিত্য');
      for (final q in paper.literature) {
        add(ParaKind.question, q.stem);
        labelled([('k', q.questionK), ('kh', q.questionKh)]);
      }
    }
    if (paper.written.isNotEmpty) {
      add(ParaKind.heading, 'লিখিত অংশ');
      for (final q in paper.written) {
        add(ParaKind.question, q.prompt);
        add(ParaKind.normal, q.sourceText ?? '');
      }
    }
    for (final section in paper.english) {
      add(ParaKind.heading, section.head);
      for (final line in section.lines) {
        add(ParaKind.normal, line);
      }
    }
    return PaperDocument(
      id: 'draft',
      title: title,
      header: PaperHeader(subject: subject, marks: marks),
      paragraphs: out,
    );
  }

  /// The question text of [paper] as a new, unsaved document.
  static PaperDocument documentFrom(SavedPaper paper) {
    final stored = paper.document;
    if (stored != null) {
      try {
        final full = PaperDocument.fromJson(stored);
        return PaperDocument(
          id: docIdFor(paper.id),
          title: paper.title,
          header: full.header,
          pageHeader: full.pageHeader,
          pageFooter: full.pageFooter,
          showPageNumbers: full.showPageNumbers,
          paragraphs: full.paragraphs,
        );
      } catch (_) {
        // A damaged stored copy falls back to the MCQ text below.
      }
    }
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
