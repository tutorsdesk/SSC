import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';

/// Local-only, bounded diagnostics. No SDK, network sender, user identifiers,
/// exception messages, prompts, attachments, filenames, URLs or credentials.
/// A future remote integration needs a separate explicit privacy decision.
class LocalDiagnostics {
  static const storageKey = 'local_diagnostics_v1';
  static const maxEntries = 10;
  static Future<void> _writes = Future.value();

  static Future<void> record(
    Object error,
    StackTrace stack, {
    String scope = 'app',
  }) {
    final frames = RegExp(
      r'package:tutors_desk/[a-zA-Z0-9_./-]+\.dart:\d+(?::\d+)?',
    ).allMatches(stack.toString()).take(12).map((m) => m.group(0)!).toList();
    return _append({
      'time': DateTime.now().toUtc().toIso8601String(),
      'version': kAppVersion,
      'build': const String.fromEnvironment(
        'BUILD_NUMBER',
        defaultValue: 'dev',
      ),
      'platform': defaultTargetPlatform.name,
      'scope': const {
        'app',
        'startup',
        'flutter',
        'async',
        'native',
        'workflow',
        'camera',
      }.contains(scope)
          ? scope
          : 'app',
      // Runtime type only; toString() often contains private payloads.
      'type': error.runtimeType.toString(),
      'frames': frames,
    });
  }

  static Future<void> _append(Map<String, Object> entry) {
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final items = prefs.getStringList(storageKey) ?? [];
        items.add(jsonEncode(entry));
        await prefs.setStringList(
          storageKey,
          items
              .skip((items.length - maxEntries).clamp(0, items.length))
              .toList(),
        );
      } catch (_) {
        // Logging must never recurse into another framework error.
      }
    });
    return _writes;
  }

  static Future<String> report() async {
    await _writes;
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = prefs.getStringList(storageKey) ?? [];
      return items.isEmpty
          ? 'No local diagnostics recorded.'
          : items.join('\n\n');
    } catch (_) {
      return 'Local diagnostics are unavailable.';
    }
  }

  static Future<void> clear() {
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(storageKey);
      } catch (_) {}
    });
    return _writes;
  }
}

/// Native crash contents are deliberately not imported or displayed.
class NativeCrashDetected implements Exception {}
