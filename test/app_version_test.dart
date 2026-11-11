import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tutors_desk/services/app_version.dart';

void main() {
  test('kAppVersion matches the version name in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9.]+)\+',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version line');
    expect(kAppVersion, match!.group(1));
  });
}
