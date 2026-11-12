import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_updater.dart';
import 'offline_banner.dart';

/// Update prompts. The check runs once per app launch, and Settings has a
/// manual check. Nothing downloads or installs without the user tapping
/// Update.
abstract final class AppUpdateDialogs {
  static bool _checkedThisSession = false;

  static bool get _disabled =>
      kDebugMode || Platform.environment.containsKey('FLUTTER_TEST');

  /// Once per launch, as soon as the app is open. It does not wait for the
  /// sign-in or the library restore, so the prompt also appears on the
  /// startup screen.
  static Future<void> checkOnStartup() async {
    if (_checkedThisSession || _disabled) return;
    _checkedThisSession = true;
    // The network is often not ready in the first seconds after launch, so a
    // check that could not reach GitHub is retried every few seconds for
    // about a minute. Waiting for the app's navigator does not use up a try.
    var tries = 0;
    for (var wait = 0; wait < 200 && tries < 20; wait++) {
      // The overlay sits under the app Navigator, so dialogs open from it.
      final context = rootNavigatorKey.currentState?.overlay?.context;
      if (context == null || !context.mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      tries++;
      final update = await AppUpdater.checkForUpdate();
      if (update != null) {
        if (context.mounted) await _offer(context, update);
        return;
      }
      if (!AppUpdater.lastCheckFailed) return;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
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
      // A failed check is not the same as being up to date.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppUpdater.lastCheckFailed
                ? "Couldn't check for updates. Check your connection and try again."
                : "You're on the latest version.",
          ),
        ),
      );
      return;
    }
    await _offer(context, update);
  }

  static Future<void> _offer(BuildContext context, AppUpdate update) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: const Text(
          'A new version of Tutor\'s Desk is ready. Install it now?',
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
    final navigator = Navigator.of(context, rootNavigator: true);
    final progress = ValueNotifier<_DownloadProgress>(
      const _DownloadProgress(0, null),
    );
    // The dialog stays open until the download finishes or fails.
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(progress: progress),
    );
    final File file;
    try {
      file = await AppUpdater.download(
        update,
        onProgress: (received, total) =>
            progress.value = _DownloadProgress(received, total),
      );
    } catch (_) {
      if (navigator.canPop()) navigator.pop();
      await dialog;
      progress.dispose();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The update could not be downloaded. Try again later.'),
        ),
      );
      return;
    }
    if (navigator.canPop()) navigator.pop();
    await dialog;
    progress.dispose();
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

/// Bytes received so far and the total size (null when unknown).
class _DownloadProgress {
  final int received;
  final int? total;
  const _DownloadProgress(this.received, this.total);

  /// 0.0–1.0, or null when the total size is unknown.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0).toDouble();
  }
}

class _DownloadDialog extends StatelessWidget {
  final ValueListenable<_DownloadProgress> progress;
  const _DownloadDialog({required this.progress});

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading update'),
      content: ValueListenableBuilder<_DownloadProgress>(
        valueListenable: progress,
        builder: (context, p, _) {
          final fraction = p.fraction;
          final percent =
              fraction == null ? null : '${(fraction * 100).floor()}%';
          final size = p.total == null
              ? '${_mb(p.received)} MB'
              : '${_mb(p.received)} of ${_mb(p.total!)} MB';
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: fraction),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(size,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  if (percent != null)
                    Text(
                      percent,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
