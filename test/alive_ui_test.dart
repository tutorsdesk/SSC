import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutors_desk/screens/signin_screen.dart';
import 'package:tutors_desk/screens/teacher_home_screen.dart';
import 'package:tutors_desk/services/app_settings.dart';
import 'package:tutors_desk/theme/app_theme.dart';
import 'package:tutors_desk/widgets/alive_background.dart';
import 'package:tutors_desk/widgets/alive_tab_stack.dart';
import 'package:tutors_desk/widgets/app_loader.dart';
import 'package:tutors_desk/widgets/animations.dart';
import 'package:tutors_desk/widgets/app_icon.dart';
import 'package:tutors_desk/widgets/boot_sequence.dart';
import 'package:tutors_desk/widgets/motion_policy.dart';
import 'package:tutors_desk/widgets/reference_ui.dart';
import 'package:tutors_desk/widgets/workflow_progress.dart';

Widget host(Widget child, {bool systemReduce = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: systemReduce),
          child: MotionPolicy(child: Scaffold(body: child)),
        ),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.reduceMotion.value = false;
  });

  test('reduce-motion preference survives a settings reload', () async {
    await AppSettings.setReduceMotion(true);
    AppSettings.reduceMotion.value = false;
    await AppSettings.load();
    expect(AppSettings.reduceMotion.value, isTrue);
  });

  testWidgets('system and app preferences both suppress spatial motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const Column(
          children: [
            FadeSlideIn(child: Text('Ready')),
            CountUp(value: 42),
            ActivityIndicator(),
          ],
        ),
        systemReduce: true,
      ),
    );
    expect(find.text('42'), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppIcon && widget.icon == PhosphorIcons.hourglass,
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    AppSettings.reduceMotion.value = true;
    await tester.pumpWidget(host(const ActivityIndicator()));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'loops stop for disable, reduced motion, hidden tabs and background',
    (tester) async {
      Widget tree({bool enabled = true, bool visible = true}) => host(
            TickerMode(
              enabled: visible,
              child: Pulse(enabled: enabled, child: const Text('Busy')),
            ),
          );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(tree());
      MotionLoopState<Pulse> state() => tester.state(find.byType(Pulse));
      expect(state().motion.isAnimating, isTrue);
      await tester.pumpWidget(tree(enabled: false));
      expect(state().motion.isAnimating, isFalse);
      await tester.pumpWidget(tree());
      expect(state().motion.isAnimating, isTrue);
      await tester.pumpWidget(tree(visible: false));
      expect(state().motion.isAnimating, isFalse);
      await tester.pumpWidget(tree());
      AppSettings.reduceMotion.value = true;
      await tester.pump();
      expect(state().motion.isAnimating, isFalse);
      AppSettings.reduceMotion.value = false;
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(state().motion.isAnimating, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state().motion.isAnimating, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab navigation retains entered text but hides inactive semantics',
    (tester) async {
      var tab = 0;
      late StateSetter update;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AliveTabStack(
                index: tab,
                children: const [
                  TextField(
                    key: ValueKey('draft'),
                    decoration: InputDecoration(labelText: 'Unsent draft'),
                  ),
                  Text('Scan workspace'),
                ],
              );
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Keep my draft');
      update(() => tab = 1);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Scan workspace'), findsOneWidget);
      update(() => tab = 0);
      await tester.pumpAndSettle();
      expect(find.text('Keep my draft'), findsOneWidget);
    },
  );

  testWidgets('tactile controls support keyboard activation', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        PressableScale(
          onTap: () => calls++,
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Open paper'),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('teacher dashboard renders above its bottom navigation', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: const TeacherHomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final dashboardException = tester.takeException();
    expect(
      dashboardException,
      isNull,
      reason: 'dashboard build failed: $dashboardException',
    );
    expect(find.text("Tutor's Desk"), findsOneWidget);
    expect(find.text('CREATE PAPER'), findsOneWidget);
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.text('My Papers'), findsOneWidget);
    expect(find.byType(ReferenceBottomBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('dashboard content is given finite horizontal constraints', () {
    final home = File(
      'lib/screens/teacher_home_screen.dart',
    ).readAsStringSync();
    final navigation = File('lib/widgets/reference_ui.dart').readAsStringSync();

    expect(
      home,
      matches(
        RegExp(
          r'Widget _referenceDashboard\(\) => SizedBox\(\s*'
          r'width: double\.infinity,\s*child: Center',
        ),
      ),
    );
    expect(
      navigation,
      matches(
        RegExp(
          r'Widget build\(BuildContext context\) => SizedBox\(\s*'
          r'width: double\.infinity,\s*height: 106,\s*child: Align',
        ),
      ),
    );
  });

  testWidgets('startup screen uses a white black and grey palette', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      host(
        BootSequence(
          steps: [BootStep('Bank', () => pending.future)],
          child: const Text('Workspace ready'),
        ),
      ),
    );
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, Colors.white);
    expect(find.byType(AppLoader), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Tutor’s Desk')).style?.color,
      Colors.black,
    );
    expect(
      tester
          .widget<Text>(find.text('Getting your workspace ready…'))
          .style
          ?.color,
      Colors.grey,
    );
    pending.complete();
  });

  testWidgets(
    'startup paints before work and preserves task dependency order',
    (tester) async {
      final bank = Completer<void>();
      final cache = Completer<void>();
      final calls = <String>[];
      await tester.pumpWidget(
        host(
          BootSequence(
            steps: [
              BootStep('Bank', () {
                calls.add('bank');
                return bank.future;
              }),
              BootStep('Cache', () {
                calls.add('cache');
                return cache.future;
              }),
            ],
            child: const Text('Workspace ready'),
          ),
        ),
      );
      expect(find.byType(AppLoader), findsOneWidget);
      expect(calls, ['bank']);
      expect(find.text('Workspace ready'), findsNothing);
      bank.complete();
      await tester.pump();
      expect(calls, ['bank', 'cache']);
      cache.complete();
      await tester.pumpAndSettle();
      expect(find.text('Workspace ready'), findsOneWidget);
    },
  );

  testWidgets('startup retry does not repeat completed work or open early', (
    tester,
  ) async {
    var firstCalls = 0;
    var attempts = 0;
    AppSettings.reduceMotion.value = true;
    await tester.pumpWidget(
      host(
        BootSequence(
          steps: [
            BootStep('Preferences', () async {
              firstCalls++;
            }),
            BootStep('Bank', () async {
              if (++attempts == 1) throw StateError('private detail');
            }),
          ],
          child: const Text('Workspace ready'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Workspace ready'), findsNothing);
    expect(find.textContaining('private detail'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(firstCalls, 1);
    expect(attempts, 2);
    expect(find.text('Workspace ready'), findsOneWidget);
  });

  testWidgets(
    'workflow is bounded and reports actual activity without percent',
    (tester) async {
      AppSettings.reduceMotion.value = true;
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              WorkflowProgress(steps: [], current: 99),
              WorkflowProgress(steps: ['Subject', 'Review'], current: 99),
              OperationNotice(activity: 'Checking answers independently'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 2  •  Review'), findsOneWidget);
      expect(find.text('Checking answers independently'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('verified'), findsNothing);
    },
  );

  testWidgets('sign-in remains scrollable on a narrow large-text screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppSettings.reduceMotion.value = true;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.25),
            disableAnimations: true,
          ),
          child: const SignInScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tutor’s Desk'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.ensureVisible(find.text('Forgot password?'));
    expect(tester.takeException(), isNull);
  });

  test(
    'release signing never falls back and uploads require production configuration',
    () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
      expect(gradle, contains('dependsOn(validateProductionSigning)'));
      expect(gradle, contains('RELEASE_CERT_SHA256'));
      expect(gradle, contains('Android Debug'));
      final workflow = File(
        '.github/workflows/build_apk.yml',
      ).readAsStringSync();
      expect(workflow, contains('Verify APK certificates before distribution'));
      expect(workflow, contains('APK delivery blocked'));
      expect(workflow, isNot(contains('flutter build apk --debug')));
    },
  );
}
