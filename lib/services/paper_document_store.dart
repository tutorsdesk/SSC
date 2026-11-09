import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/paper_document.dart';
import 'local_account_scope.dart';

/// Saved Paper Editor documents: one JSON file per document, kept in the
/// signed-in tutor's own folder (the same account scoping as the paper
/// library).
abstract final class PaperDocumentStore {
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory(
      '${base.path}${sep}tutors_desk_editor${sep}accounts$sep'
      '${LocalAccountScope.id}',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static File _fileFor(Directory dir, String id) {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError('Invalid document id');
    }
    return File('${dir.path}${Platform.pathSeparator}$id.json');
  }

  /// All saved documents, newest first. Unreadable files are skipped.
  static Future<List<PaperDocument>> list() async {
    final dir = await _dir();
    final docs = <PaperDocument>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = json.decode(await entity.readAsString());
        if (raw is Map<String, dynamic>) {
          docs.add(PaperDocument.fromJson(raw));
        }
      } catch (_) {
        // A damaged file must not hide the other documents.
      }
    }
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return docs;
  }

  /// Writes the document atomically (temp file, then rename).
  static Future<void> save(PaperDocument doc) async {
    final dir = await _dir();
    final file = _fileFor(dir, doc.id);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json.encode(doc.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  static Future<void> delete(String id) async {
    final dir = await _dir();
    final file = _fileFor(dir, id);
    if (file.existsSync()) await file.delete();
  }
}
