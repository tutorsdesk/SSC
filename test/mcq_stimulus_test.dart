import 'package:flutter_test/flutter_test.dart';
import 'package:tutors_desk/services/mcq_stimulus.dart';

void main() {
  test('a stimulus is split from its numbered question', () {
    final r = splitMcqStimulus('উদ্দীপক: গল্পটি পড়ো।\n\nকোন ফুল?');
    expect(r.stimulus, 'উদ্দীপক: গল্পটি পড়ো।');
    expect(r.body, 'কোন ফুল?');
  });

  test('plain questions are left unchanged', () {
    final r = splitMcqStimulus('কোন ফুল?');
    expect(r.stimulus, isNull);
    expect(r.body, 'কোন ফুল?');
  });
}
