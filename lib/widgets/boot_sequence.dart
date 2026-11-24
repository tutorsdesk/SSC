import 'dart:async';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/local_diagnostics.dart';
import 'app_loader.dart';
import 'app_icon.dart';

class BootStep {
  final String label;
  final Future<void> Function() run;
  const BootStep(this.label, this.run);
}

/// Paint first, then initialize in dependency order. Steps run behind one
/// calm loading screen (no step checklist). Completed steps are not repeated
/// on retry; failures never expose partially initialized app routes.
class BootSequence extends StatefulWidget {
  final List<BootStep> steps;
  final Widget child;
  const BootSequence({super.key, required this.steps, required this.child});
  @override
  State<BootSequence> createState() => _BootSequenceState();
}

class _BootSequenceState extends State<BootSequence> {
  int completed = 0;
  bool failed = false;
  bool running = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) start();
    });
  }

  Future<void> start() async {
    if (running) return;
    setState(() {
      failed = false;
      running = true;
    });
    while (mounted && completed < widget.steps.length) {
      try {
        await widget.steps[completed].run();
        if (!mounted) return;
        setState(() => completed++);
      } catch (error, stack) {
        unawaited(LocalDiagnostics.record(error, stack, scope: 'startup'));
        if (!mounted) return;
        setState(() {
          failed = true;
          running = false;
        });
        return;
      }
    }
    running = false;
  }

  @override
  Widget build(BuildContext context) {
    if (completed == widget.steps.length) return widget.child;
    if (!failed) return const AppLoader();
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(
                  PhosphorIcons.warningCircle,
                  size: 40,
                  color: Colors.grey,
                ),
                const SizedBox(height: 16),
                const Text(
                  'We could not finish opening the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your saved data has not been cleared.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: start,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  icon: const AppIcon(PhosphorIcons.arrowClockwise),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
