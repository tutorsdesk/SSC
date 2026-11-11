import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutors_desk/services/local_account_scope.dart';
import 'package:tutors_desk/services/local_diagnostics.dart';
import 'package:tutors_desk/services/paper_library.dart';

/// Backups must survive an uninstall: the app-scoped copy Android deletes is
/// not enough, so the shared Download/TutorsDesk copy is what a reinstall
/// restores. These tests drive the real PaperLibrary/PaperBackup code paths
/// with stubbed platform channels only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const storage = MethodChannel('com.tutorsdesk.app/storage');

  late Directory appDoc;
  late Directory external;
  late Directory sdcard;
  late List<Map<String, Object?>> calls;
  late bool sharedWritable;

  setUp(() async {
    appDoc = Directory.systemTemp.createTempSync('td_app_');
    external = Directory.systemTemp.createTempSync('td_ext_');
    sdcard = Directory.systemTemp.createTempSync('td_sd_');
    SharedPreferences.setMockInitialValues({});
    LocalAccountScope.debugId = 'signed_out';
    await LocalDiagnostics.clear();
    calls = <Map<String, Object?>>[];
    sharedWritable = true;
    PaperBackup.debugBaseDir =
        () async => Directory('${external.path}/TutorsDesk');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
          return appDoc.path;
        case 'getExternalStorageDirectory':
          return external.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(storage, (call) async {
      calls.add({
        'method': call.method,
        ...Map<String, Object?>.from(call.arguments as Map? ?? const {}),
      });
      switch (call.method) {
        case 'canManageAllFiles':
          return true;
        case 'externalStorageDir':
          return sdcard.path;
        case 'copyToDownloads':
          if (!sharedWritable) return null;
          // Mirror the real MediaStore route: the destination is relative to
          // the shared storage root, exactly where the restore looks for it.
          final args = Map<String, Object?>.from(call.arguments as Map);
          final relative =
              (args['relativePath'] as String?) ?? 'Download/TutorsDeskDebug';
          final name = args['name'] as String;
          final target = File('${sdcard.path}/$relative/$name');
          target.parent.createSync(recursive: true);
          target.writeAsBytesSync(
            File(args['source'] as String).readAsBytesSync(),
          );
          return '$relative/$name';
      }
      return null;
    });
  });

  tearDown(() {
    PaperBackup.debugBaseDir = null;
    LocalAccountScope.debugId = null;
    for (final dir in [appDoc, external, sdcard]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  SavedPaper paper({String id = 'sp_1'}) => SavedPaper(
        id: id,
        title: 'Physics Model Test',
        subject: 'Physics',
        subjectId: 'physics',
        subjectCode: '109',
        setCode: 'ক',
        total: 1,
        key: const [2],
        questions: const [
          SavedQuestion(
            text: 'ত্বরণের একক কী?',
            options: ['m/s', 'm', 'm/s²', 'kg'],
            answer: 2,
          ),
        ],
        createdAt: DateTime(2026, 9, 26),
        pages: 1,
      );

  File inAppCopy() =>
      File('${external.path}/TutorsDesk/tutors_desk_backup_signed_out.json');

  File sharedCopy() => File(
        '${sdcard.path}/Download/TutorsDesk/tutors_desk_backup_signed_out.json',
      );

  /// Included in failure messages so a CI failure explains itself instead of
  /// only reporting a bare false.
  Future<String> why() async =>
      'calls=${calls.map((c) => c['method']).toList()} '
      'shared=${sharedCopy().existsSync()} inApp=${inAppCopy().existsSync()} '
      'diag=${await LocalDiagnostics.report()}';

  test('paper library and backups are isolated between accounts', () async {
    LocalAccountScope.debugId = 'account_a';
    await PaperLibrary.addSavedPaper(paper(id: 'only_a'));
    await PaperBackup.autoSave();

    LocalAccountScope.debugId = 'account_b';
    expect(await PaperLibrary.loadEntries(), isEmpty);
    expect(await PaperLibrary.savedPaper('only_a'), isNull);
    expect(
      File(
        '${external.path}/TutorsDesk/'
        'tutors_desk_backup_account_a.json',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${external.path}/TutorsDesk/'
        'tutors_desk_backup_account_b.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('saving a paper writes the uninstall-surviving Download copy', () async {
    await PaperLibrary.addSavedPaper(paper());
    await PaperBackup.autoSave();

    expect(
      inAppCopy().existsSync(),
      isTrue,
      reason: 'the in-app copy still keeps working offline',
    );
    expect(
      sharedCopy().existsSync(),
      isTrue,
      reason: 'the shared copy is the only one that survives an uninstall',
    );

    final request = calls.firstWhere((c) => c['method'] == 'copyToDownloads');
    expect(
      request['relativePath'],
      'Download/TutorsDesk',
      reason: 'must not reuse the TutorsDeskDebug folder the restore ignores',
    );
    expect(request['name'], 'tutors_desk_backup_signed_out.json');
    expect(request['mime'], 'application/json');

    final backup = jsonDecode(sharedCopy().readAsStringSync()) as Map;
    expect(backup['app'], 'tutors_desk');
    expect(backup['entries'], isNotEmpty);
  });

  test('a fresh install restores the paper and its answer key', () async {
    await PaperLibrary.addSavedPaper(paper());
    await PaperBackup.autoSave();
    expect(sharedCopy().existsSync(), isTrue);

    // Uninstall: Android removes the app folders, shared Download stays.
    appDoc.deleteSync(recursive: true);
    external.deleteSync(recursive: true);
    appDoc.createSync(recursive: true);
    external.createSync(recursive: true);

    expect(await PaperLibrary.loadEntries(), isEmpty);
    expect(await PaperBackup.tryAutoRestore(), 1, reason: await why());

    final entries = await PaperLibrary.loadEntries();
    expect(entries.map((e) => e.id), contains('sp_1'));
    final restored = await PaperLibrary.savedPaper('sp_1');
    expect(restored?.key, [2], reason: 'the OMR answer key must come back');
    expect(restored?.questions.single.text, 'ত্বরণের একক কী?');
  });

  test(
    'manual export reports failure honestly when shared storage refuses',
    () async {
      await PaperLibrary.addSavedPaper(paper());
      await PaperBackup.autoSave();
      expect(inAppCopy().existsSync(), isTrue);
      sharedWritable = false;
      calls.clear();

      expect(await PaperBackup.exportToDownload(), isNull);
      expect(calls.any((c) => c['method'] == 'copyToDownloads'), isTrue);
      expect(
        inAppCopy().existsSync(),
        isTrue,
        reason: 'a failed shared copy must not lose the in-app backup',
      );
    },
  );

  test('the shared copy survives an unusable in-app folder', () async {
    await PaperLibrary.addSavedPaper(paper());
    PaperBackup.debugBaseDir = () async => throw StateError('storage gone');

    expect(
      await PaperBackup.exportToDownload(),
      'Download/TutorsDesk/tutors_desk_backup_signed_out.json',
      reason:
          'the uninstall-safe copy must not depend on app storage; ${await why()}',
    );
    expect(sharedCopy().existsSync(), isTrue);
  });

  test('an empty library never overwrites an existing backup', () async {
    await PaperLibrary.addSavedPaper(paper());
    await PaperBackup.autoSave();
    expect(sharedCopy().existsSync(), isTrue);

    // Wiped library: a fresh install before restore has run, or a transient
    // read failure. The next automatic save must not empty the backup.
    File(
      '${appDoc.path}/tutors_desk_papers/accounts/signed_out/index.json',
    ).writeAsStringSync('[]');
    expect(await PaperLibrary.loadEntries(), isEmpty);

    await PaperBackup.autoSave();

    final backup = jsonDecode(sharedCopy().readAsStringSync()) as Map;
    expect(
      backup['entries'],
      isNotEmpty,
      reason: 'an empty snapshot must not erase a real backup; ${await why()}',
    );
    expect(await PaperBackup.exportToDownload(), isNull);
  });

  test('native copy writes and reports the same folder', () {
    // The destination folder must come from the caller: a hardcoded folder
    // here would put backups where the restore never looks, while the app
    // still reported success.
    final kotlin = File(
      'android/app/src/main/kotlin/com/tutorsdesk/app/MainActivity.kt',
    ).readAsStringSync();
    expect(kotlin, contains('RELATIVE_PATH, relative'));
    expect(
      kotlin,
      isNot(contains('RELATIVE_PATH, "Download/TutorsDeskDebug"')),
    );
    expect(kotlin, contains('path = relative'));
  });

  test('restore keeps existing papers instead of duplicating them', () async {
    await PaperLibrary.addSavedPaper(paper());
    await PaperBackup.autoSave();

    expect(
      await PaperBackup.tryAutoRestore(),
      0,
      reason: 'a non-empty library must never be overwritten',
    );
    final entries = await PaperLibrary.loadEntries();
    expect(entries.where((e) => e.id == 'sp_1').length, 1);
  });

  test('restore ignores unsafe imported ids and filenames', () async {
    final backup = File('${sdcard.path}/unsafe.json');
    backup.writeAsStringSync(
      jsonEncode({
        'app': 'tutors_desk',
        'entries': [
          paper(id: 'sp_safe').toJson(),
          paper(id: '../escape').toJson(),
        ],
        'files': {
          'sp_safe/paper.json': base64Encode(utf8.encode('{}')),
          '../escape/evil.txt': base64Encode(utf8.encode('secret')),
        },
      }),
    );

    expect(await PaperBackup.restore(backup), 1);
    expect((await PaperLibrary.loadEntries()).map((e) => e.id).toList(), [
      'sp_safe',
    ]);
    expect(File('${external.path}/escape/evil.txt').existsSync(), isFalse);
  });

  test('a deleted paper is not restored from an older backup', () async {
    await PaperLibrary.addSavedPaper(paper());
    await PaperBackup.autoSave();
    final stale = inAppCopy().readAsBytesSync();

    await PaperLibrary.deleteEntry('sp_1');
    await PaperBackup.autoSave();
    expect(await PaperLibrary.loadEntries(), isEmpty);

    // A copy written before the deletion is put back (old backup, sync, or a
    // reinstall reading a stale shared copy). It must not resurrect the paper.
    inAppCopy().writeAsBytesSync(stale);
    sharedCopy().writeAsBytesSync(stale);
    expect(await PaperBackup.tryAutoRestore(), 0, reason: await why());
    expect(await PaperLibrary.loadEntries(), isEmpty);
  });
}
