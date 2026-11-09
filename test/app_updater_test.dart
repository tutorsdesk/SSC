import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/services/app_updater.dart';

const _digest44 =
    '1111111111111111111111111111111111111111111111111111111111111111';

Map<String, dynamic> _release(
  String tag, {
  bool draft = false,
  String? digest,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'assets': [
        {
          'name': "Tutor'sDesk-Windows-Setup.exe",
          'browser_download_url': 'https://example.test/$tag/setup.exe',
          if (digest != null) 'digest': 'sha256:$digest',
        },
        {
          'name': 'Tutor-Portable.zip',
          'browser_download_url': 'https://example.test/$tag/portable.zip',
        },
      ],
    };

void main() {
  test('build number is read from a windows-build tag only', () {
    expect(AppUpdateRules.windowsBuildFromTag('windows-build-43'), 43);
    expect(AppUpdateRules.windowsBuildFromTag('test-build-643'), isNull);
    expect(AppUpdateRules.windowsBuildFromTag('windows-build-x'), isNull);
  });

  test('a digest is accepted only as a full sha256 value', () {
    expect(AppUpdateRules.digestFromAsset('sha256:$_digest44'), _digest44);
    expect(AppUpdateRules.digestFromAsset('sha256:abc'), isNull);
    expect(AppUpdateRules.digestFromAsset(null), isNull);
  });

  test('Windows picks the newest newer build that has a verifiable setup', () {
    final update = AppUpdateRules.pickWindowsUpdate([
      _release('windows-build-43', digest: _digest44),
      _release('windows-build-44', digest: _digest44),
      // No digest: cannot be verified, so it is never offered.
      _release('windows-build-45'),
      _release('windows-build-46', draft: true, digest: _digest44),
    ], 43);
    expect(update, isNotNull);
    expect(update!.build, 44);
    expect(update.sha256, _digest44);
    expect(update.fileName, 'TutorsDesk-Setup-44.exe');
  });

  test('Windows offers nothing when the installed build is current', () {
    expect(
      AppUpdateRules.pickWindowsUpdate([
        _release('windows-build-44', digest: _digest44),
      ], 44),
      isNull,
    );
  });

  test('Android picks the APK for the device ABI when newer', () {
    final update = AppUpdateRules.pickAndroidUpdate(
      manifest: {
        'build': 644,
        'apks': {
          'arm64-v8a': {'name': 'app-arm64-v8a-release.apk', 'sha256': _digest44},
        },
      },
      abi: 'arm64-v8a',
      assetUrls: {
        'app-arm64-v8a-release.apk': 'https://example.test/app-arm64.apk',
      },
      current: 643,
    );
    expect(update, isNotNull);
    expect(update!.build, 644);
    expect(update.url.toString(), 'https://example.test/app-arm64.apk');
    expect(update.sha256, _digest44);
  });

  test('Android offers nothing for the same build, an unknown ABI, or no asset',
      () {
    final manifest = {
      'build': 644,
      'apks': {
        'arm64-v8a': {'name': 'app-arm64-v8a-release.apk', 'sha256': _digest44},
      },
    };
    expect(
      AppUpdateRules.pickAndroidUpdate(
        manifest: manifest,
        abi: 'arm64-v8a',
        assetUrls: const {'app-arm64-v8a-release.apk': 'https://x'},
        current: 644,
      ),
      isNull,
    );
    expect(
      AppUpdateRules.pickAndroidUpdate(
        manifest: manifest,
        abi: 'mips',
        assetUrls: const {'app-arm64-v8a-release.apk': 'https://x'},
        current: 643,
      ),
      isNull,
    );
    expect(
      AppUpdateRules.pickAndroidUpdate(
        manifest: manifest,
        abi: 'arm64-v8a',
        assetUrls: const {},
        current: 643,
      ),
      isNull,
    );
  });

  test('SHA-256 of a known input matches the published test vector', () {
    expect(
      sha256.convert('abc'.codeUnits).toString(),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
