import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_updater.dart';

/// Update prompts. The check runs once per app launch, and Settings has a
/// manual check. Nothing downloads or installs without the user tapping
/// Update.
abstract final class AppUpdateDialogs {
  static bool _checkedThisSession = false;

  static bool get _disabled =>
      kDebugMode || Platform.environment.containsKey('FLUTTER_TEST');

  /// Once per launch, after the first screen is up.
  static Future<void> checkOnStartup(BuildContext context) async {
    if (_checkedThisSession || _disabled) return;
    _checkedThisSession = true;
    final update = await AppUpdater.checkForUpdate();
    if (update == null || !context.mounted) return;
    await _offer(context, update);
  }

  /// From Settings. Tells the user when they are already up to date.
  static Future<void> checkNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Checking for updates…')),
    );
    final update = await AppUpdater.checkForUpdate();
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    if (update == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("You're on the latest build.")),
      );
      return;
    }
    await _offer(context, update);
  }

  static Future<void> _offer(BuildContext context, AppUpdate update) async {
    final current = AppUpdater.currentBuild;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text(
          current == 0
              ? 'Build ${update.build} is ready. Install it now?'
              : 'Build ${update.build} is ready (you have build $current). '
                  'Install it now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await _downloadAndInstall(context, update);
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    AppUpdate update,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading the update…'),
        duration: Duration(minutes: 10),
      ),
    );
    final File file;
    try {
      file = await AppUpdater.download(update);
    } catch (_) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The update could not be downloaded. Try again later.'),
        ),
      );
      return;
    }
    messenger.hideCurrentSnackBar();
    final String result;
    try {
      result = await AppUpdater.install(update, file);
    } on PlatformException {
      messenger.showSnackBar(
        const SnackBar(content: Text('The installer could not be opened.')),
      );
      return;
    }
    if (!context.mounted) return;
    if (result == 'needs_permission') {
      messenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 8),
          content: Text(
            'Allow installs from Tutor’s Desk on the screen that just opened, '
            'then tap Check for updates again.',
          ),
        ),
      );
      return;
    }
    if (Platform.isWindows) {
      // The silent setup replaces this app and relaunches it when finished.
      await Future<void>.delayed(const Duration(seconds: 1));
      exit(0);
    }
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 8),
        content: Text('Follow the installer to finish the update.'),
      ),
    );
  }
}
