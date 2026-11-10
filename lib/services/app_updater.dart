import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// One downloadable build that is newer than the one running.
class AppUpdate {
  const AppUpdate({
    required this.build,
    required this.url,
    required this.sha256,
    required this.fileName,
  });

  final int build;
  final Uri url;

  /// Expected SHA-256 of the download, lowercase hex.
  final String sha256;

  /// Local file name for the download (no spaces or apostrophes).
  final String fileName;
}

/// Pure selection rules. They take already-decoded GitHub JSON, so they can be
/// tested without a network.
abstract final class AppUpdateRules {
  static final RegExp _windowsTag = RegExp(r'^windows-build-(\d+)$');
  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Build number from a tag such as `windows-build-43`, or null.
  static int? windowsBuildFromTag(String tag) {
    final m = _windowsTag.firstMatch(tag);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// SHA-256 digest from a GitHub asset digest (`sha256:<hex>`), or null.
  static String? digestFromAsset(Object? digest) {
    if (digest is! String || !digest.startsWith('sha256:')) return null;
    final hex = digest.substring(7).toLowerCase();
    return _hex64.hasMatch(hex) ? hex : null;
  }

  /// The newest Windows setup newer than [current]. A release is used only
  /// when its setup has a published SHA-256 digest, so an unverifiable
  /// download is never offered.
  static AppUpdate? pickWindowsUpdate(
    List<Map<String, dynamic>> releases,
    int current,
  ) {
    AppUpdate? best;
    for (final r in releases) {
      if (r['draft'] == true) continue;
      final build = windowsBuildFromTag('${r['tag_name'] ?? ''}');
      if (build == null || build <= current) continue;
      if (best != null && build <= best.build) continue;
      final assets = (r['assets'] as List?) ?? const [];
      for (final a in assets.whereType<Map>()) {
        final name = '${a['name'] ?? ''}';
        if (!name.endsWith('-Setup.exe')) continue;
        final digest = digestFromAsset(a['digest']);
        final url = a['browser_download_url'];
        if (digest == null || url is! String) break;
        best = AppUpdate(
          build: build,
          url: Uri.parse(url),
          sha256: digest,
          fileName: 'TutorsDesk-Setup-$build.exe',
        );
        break;
      }
    }
    return best;
  }

  /// The Android APK for [abi] when the update manifest is newer than
  /// [current]. [assetUrls] maps asset names to download URLs.
  static AppUpdate? pickAndroidUpdate({
    required Map<String, dynamic> manifest,
    required String abi,
    required Map<String, String> assetUrls,
    required int current,
  }) {
    final build = manifest['build'];
    if (build is! int || build <= current) return null;
    final apks = manifest['apks'];
    if (apks is! Map) return null;
    final entry = apks[abi];
    if (entry is! Map) return null;
    final name = entry['name'];
    final digest = digestFromAsset('sha256:${entry['sha256']}');
    final url = name is String ? assetUrls[name] : null;
    if (url == null || digest == null) return null;
    return AppUpdate(
      build: build,
      url: Uri.parse(url),
      sha256: digest,
      fileName: 'TutorsDesk-$build-$abi.apk',
    );
  }
}

/// Checks GitHub for a newer build of the running app and installs it.
///
/// Android: the `android-latest` release carries an `android-update.json`
/// manifest. The matching APK is downloaded, verified, and handed to the
/// system installer, which asks the user once to confirm.
/// Windows: the newest `windows-build-N` release with a setup is downloaded,
/// verified, and run silently. The installer upgrades in place.
abstract final class AppUpdater {
  /// Build number baked in by CI with `--dart-define=BUILD_NUMBER=<run>`.
  static const int currentBuild = int.fromEnvironment(
    'BUILD_NUMBER',
    defaultValue: 0,
  );

  static const String repo = 'tutorsdesk/SSC';
  static const MethodChannel _channel = MethodChannel(
    'com.tutorsdesk.app/update',
  );
  static const Duration _timeout = Duration(seconds: 30);

  static Map<String, String> get _headers => const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// The update for this platform, or null when up to date or unknown.
  static Future<AppUpdate?> checkForUpdate() async {
    if (Platform.isAndroid) return _checkAndroid();
    if (Platform.isWindows) return _checkWindows();
    return null;
  }

  static Future<AppUpdate?> _checkAndroid() async {
    final release = await _getJson(
      'https://api.github.com/repos/$repo/releases/tags/android-latest',
    );
    if (release is! Map) return null;
    final assetUrls = <String, String>{};
    String? manifestUrl;
    for (final a in (release['assets'] as List?) ?? const []) {
      if (a is! Map) continue;
      final name = '${a['name'] ?? ''}';
      final url = '${a['browser_download_url'] ?? ''}';
      assetUrls[name] = url;
      if (name == 'android-update.json') manifestUrl = url;
    }
    if (manifestUrl == null) return null;
    final manifest = await _getJson(manifestUrl);
    if (manifest is! Map<String, dynamic>) return null;
    final abi = await _deviceAbi();
    if (abi == null) return null;
    return AppUpdateRules.pickAndroidUpdate(
      manifest: manifest,
      abi: abi,
      assetUrls: assetUrls,
      current: currentBuild,
    );
  }

  static Future<AppUpdate?> _checkWindows() async {
    final releases = await _getJson(
      'https://api.github.com/repos/$repo/releases?per_page=30',
    );
    if (releases is! List) return null;
    return AppUpdateRules.pickWindowsUpdate(
      [
        for (final r in releases)
          if (r is Map<String, dynamic>) r,
      ],
      currentBuild,
    );
  }

  static Future<String?> _deviceAbi() async {
    try {
      final abi = await _channel.invokeMethod<String>('deviceAbi');
      return (abi == null || abi.isEmpty) ? null : abi;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<Object?> _getJson(String url) async {
    try {
      final res =
          await http.get(Uri.parse(url), headers: _headers).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// Downloads [update] into the temporary `updates` folder and verifies its
  /// SHA-256 before returning the file path. Throws on any mismatch.
  ///
  /// [onProgress] is called as bytes arrive with the bytes received so far and
  /// the total size, or null when the server does not report a size.
  static Future<File> download(
    AppUpdate update, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = await _fetch(update, onProgress);
    final actual = sha256.convert(bytes).toString();
    if (actual != update.sha256) {
      throw const FormatException('Download did not match its checksum.');
    }
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
    await dir.create(recursive: true);
    // Keep only the newest download.
    await for (final f in dir.list()) {
      if (f is File) {
        try {
          await f.delete();
        } catch (_) {
          // An old file that cannot be removed is harmless.
        }
      }
    }
    final file = File('${dir.path}${Platform.pathSeparator}${update.fileName}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<Uint8List> _fetch(
    AppUpdate update,
    void Function(int received, int? total)? onProgress,
  ) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', update.url)).timeout(
            const Duration(minutes: 2),
          );
      if (res.statusCode != 200) {
        throw HttpException('Download failed (${res.statusCode}).');
      }
      final total = res.contentLength != null && res.contentLength! > 0
          ? res.contentLength
          : null;
      final builder = BytesBuilder(copy: false);
      var received = 0;
      // Inactivity timeout: a stalled download fails, a slow one does not.
      await for (final chunk
          in res.stream.timeout(const Duration(minutes: 1))) {
        builder.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  /// Starts the installer. Android returns `started` or `needs_permission`
  /// (the user must allow installs from this app first). Windows starts the
  /// silent setup and returns `started`; the caller should then exit the app.
  static Future<String> install(AppUpdate update, File file) async {
    if (Platform.isAndroid) {
      final r = await _channel.invokeMethod<String>('installApk', {
        'path': file.path,
      });
      return r ?? 'started';
    }
    await Process.start(
      file.path,
      const ['/SILENT', '/NORESTART', '/SUPPRESSMSGBOXES'],
      mode: ProcessStartMode.detached,
    );
    return 'started';
  }
}
