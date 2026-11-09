import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/paper_document.dart';
import 'local_account_scope.dart';

/// Saved Paper Editor documents: one JSON file per document, kept in the
/// signed-in tutor's own folder (the same account scoping as the paper
/// library).
///
/// Saves also write a timestamped copy to a `backup` folder beside the
/// documents (at most every 10 minutes); the newest [_keepBackups] copies per
/// document are kept.
/// Documents can be exported to and imported from a `.json` file.
abstract final class PaperDocumentStore {
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]+$');
  static const int _keepBackups = 10;
  static const String exportExtension = 'tdpaper';

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

  static Future<Directory> _backupDir() async {
    final dir = await _dir();
    final sep = Platform.pathSeparator;
    final backup = Directory('${dir.path}${sep}backup');
    if (!backup.existsSync()) backup.createSync(recursive: true);
    return backup;
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
      final doc = await _readFile(entity);
      if (doc != null) docs.add(doc);
    }
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return docs;
  }

  /// Writes the document atomically (temp file, then rename), then writes a
  /// backup copy and prunes old backups of the same document.
  static Future<void> save(PaperDocument doc) async {
    final dir = await _dir();
    final file = _fileFor(dir, doc.id);
    final text = json.encode(doc.toJson());
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
    await _writeBackup(doc.id, text);
  }

  /// Backups are taken at most every [_backupEvery], so the kept copies span
  /// a long editing session rather than the last few autosaves.
  static const Duration _backupEvery = Duration(minutes: 10);

  static Future<void> _writeBackup(String id, String text) async {
    final backupDir = await _backupDir();
    final existing = await backupsIn(backupDir, id);
    if (existing.isNotEmpty &&
        DateTime.now().difference(existing.first.lastModifiedSync()) <
            _backupEvery) {
      return;
    }
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final sep = Platform.pathSeparator;
    final file = File('${backupDir.path}$sep${id}_$stamp.json');
    await file.writeAsString(text, flush: true);
    await _pruneBackups(backupDir, id);
  }

  static Future<void> _pruneBackups(Directory backupDir, String id) async {
    final files = await backupsIn(backupDir, id);
    for (final old in files.skip(_keepBackups)) {
      try {
        await old.delete();
      } catch (_) {
        // A locked backup is left for the next save.
      }
    }
  }

  /// Backup copies of document [id], newest first.
  static Future<List<File>> backups(String id) async {
    if (!_safeId.hasMatch(id)) return const [];
    return backupsIn(await _backupDir(), id);
  }

  static Future<List<File>> backupsIn(Directory backupDir, String id) async {
    final prefix = '${id}_';
    final files = <File>[];
    await for (final entity in backupDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith(prefix) && name.endsWith('.json')) files.add(entity);
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Reads a backup or exported file. Returns null if it is not a document.
  static Future<PaperDocument?> readBackup(File file) => _readFile(file);

  static Future<PaperDocument?> _readFile(File file) async {
    try {
      final raw = json.decode(await file.readAsString());
      if (raw is Map<String, dynamic>) return PaperDocument.fromJson(raw);
    } catch (_) {
      // A damaged file must not hide the other documents.
    }
    return null;
  }

  static Future<void> delete(String id) async {
    final dir = await _dir();
    final file = _fileFor(dir, id);
    if (file.existsSync()) await file.delete();
  }

  /// Saves a copy of [doc] to a location the tutor picks. Returns the saved
  /// path, or null if the tutor cancelled.
  static Future<String?> exportDocument(PaperDocument doc) async {
    final bytes = Uint8List.fromList(
      utf8.encode(json.encode(doc.toJson())),
    );
    final name = '${_safeName(doc.title)}.$exportExtension';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export paper',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: [exportExtension],
      bytes: bytes,
    );
    if (path == null) return null;
    // Desktop platforms return only the path, so write the file here too.
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (desktop) await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Lets the tutor pick an exported file and returns it as a new document
  /// (with a fresh id, so it never overwrites an existing paper). Returns
  /// null if the tutor cancelled or the file is not a valid paper.
  static Future<PaperDocument?> importDocument() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import paper',
      type: FileType.custom,
      allowedExtensions: [exportExtension, 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes = picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) return null;
    try {
      final raw = json.decode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic>) return null;
      PaperDocument.fromJson(raw); // validates the file
      return PaperDocument.fromJson({...raw, 'id': newDocId()});
    } catch (_) {
      return null;
    }
  }

  static String _safeName(String title) {
    final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    return clean.isEmpty ? 'paper' : clean;
  }
}
