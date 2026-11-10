import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'data/question_bank.dart';
import 'navigation/app_routes.dart';
import 'data/question_sync.dart';
import 'data/english_paper_sync.dart';
import 'data/content_catalog_sync.dart';
import 'services/app_settings.dart';
import 'services/local_diagnostics.dart';
import 'widgets/boot_sequence.dart';
import 'widgets/motion_policy.dart';
import 'services/app_style.dart';
import 'services/auth_service.dart';
import 'services/paper_library.dart';
import 'theme/app_theme.dart';
import 'screens/root_gate.dart';
import 'widgets/alive_background.dart';
import 'widgets/offline_banner.dart';
import 'widgets/app_update_dialogs.dart';
import 'widgets/app_icon.dart';

// Set by _readCrashLog(); consumed by _CrashReportGate after the first
// frame so the dialog can use a live navigator.
String? _pendingCrashReport;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => _FriendlyErrorView(details: details);
  FlutterError.onError = (details) {
    unawaited(
      LocalDiagnostics.record(
        details.exception,
        details.stack ?? StackTrace.empty,
        scope: 'flutter',
      ),
    );
    if (kDebugMode) FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(LocalDiagnostics.record(error, stack, scope: 'async'));
    return true;
  };
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
  // No asset, preference or network wait before the first frame.
  runApp(const ALearningApp());
  // The update check starts with the app, not after sign-in or the library
  // restore, so a new build is offered as soon as the app opens.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(AppUpdateDialogs.checkOnStartup()),
  );
}

List<BootStep> _bootSteps() => [
      BootStep('Restoring your preferences', () async {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        await AppStyle.load();
        await AppSettings.load();
      }),
      BootStep('Loading the question bank', QuestionBank.load),
      BootStep('Restoring saved content', () async {
        // Cached overlays MUST follow the bundled bank, never race it.
        await QuestionSync.loadCache();
        await EnglishPaperSync.loadCache();
        await ContentCatalogSync.loadCache();
      }),
      BootStep('Restoring sign-in', AuthService.init),
      BootStep('Preparing your paper library', () async {
        // Wait for restoration before home/library can read the files.
        await PaperBackup.tryAutoRestore();
        _pendingCrashReport = await _readCrashLog();
        // These services handle offline errors; network sync never blocks boot.
        unawaited(QuestionSync.refresh());
        unawaited(EnglishPaperSync.refresh());
        unawaited(ContentCatalogSync.refresh());
      }),
    ];

/// Consume only the presence of a native crash, never its private message.
/// Clean up both the corrected location and the old misplaced log.
Future<String?> _readCrashLog() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    var found = false;
    for (final path in [
      '${dir.path}/crash.log',
      '${support.path}/app_flutter/crash.log',
    ]) {
      final file = File(path);
      if (await file.exists()) {
        found = true;
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (found) {
      await LocalDiagnostics.record(
        NativeCrashDetected(),
        StackTrace.empty,
        scope: 'native',
      );
      return 'The previous session ended unexpectedly. A privacy-safe event was saved on this device. Review or clear it in Settings. No report was sent.';
    }
  } catch (_) {}
  return null;
}

class ALearningApp extends StatelessWidget {
  const ALearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: "Tutor's Desk",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      home: BootSequence(steps: _bootSteps(), child: const _CrashReportGate()),
      onGenerateRoute: AppRoutes.generate,
      // Every screen (pushed routes included) sits on the animated backdrop,
      // and text never scales past a readable size on large-font devices.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.85,
              maxScaleFactor: 1.25,
            ),
          ),
          child: MotionPolicy(
            child: ConnectivityBanner(
              child: AliveBackground(child: child ?? const SizedBox.shrink()),
            ),
          ),
        );
      },
    );
  }
}

/// Wraps the app root; if the previous session crashed, shows the saved
/// report once (first frame) so a crash is never silent.
class _CrashReportGate extends StatefulWidget {
  const _CrashReportGate();

  @override
  State<_CrashReportGate> createState() => _CrashReportGateState();
}

class _CrashReportGateState extends State<_CrashReportGate> {
  @override
  void initState() {
    super.initState();
    if (_pendingCrashReport != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showReport());
    }
  }

  void _showReport() {
    if (!mounted) return;
    final report = _pendingCrashReport;
    _pendingCrashReport = null;
    if (report == null) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('The app crashed last time'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3F3),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE3B3B3)),
                ),
                child: Text(
                  report,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    fontFamily: 'monospace',
                    color: Color(0xFF7A2020),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const RootGate();
}

/// Replaces Flutter's default red error box with a calm, on-brand card.
class _FriendlyErrorView extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FriendlyErrorView({required this.details});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.canvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(
                PhosphorIcons.wrench,
                color: AppTheme.accent,
                size: 44,
              ),
              const SizedBox(height: 14),
              const Text(
                'Something did not load correctly',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please go back and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.muted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 14),
                Text(
                  details.exceptionAsString(),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.danger,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
