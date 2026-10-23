import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app_info.dart';

/// A release published on GitHub, reduced to what the app needs.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.pageUrl,
    this.notes = '',
    this.apkUrl,
    this.apkBytes,
    this.windowsUrl,
    this.windowsBytes,
  });

  final String version;
  final String tag;
  final String pageUrl;
  final String notes;

  final String? apkUrl;
  final int? apkBytes;
  final String? windowsUrl;
  final int? windowsBytes;

  /// The asset for the platform the app is running on.
  String? get assetUrl => Platform.isAndroid ? apkUrl : windowsUrl;
  int? get assetBytes => Platform.isAndroid ? apkBytes : windowsBytes;
}

enum DownloadState { idle, running, done, failed }

/// A snapshot of the Android foreground-service download.
class BackgroundDownload {
  const BackgroundDownload({
    required this.state,
    this.progress = 0,
    this.path,
    this.error,
  });

  const BackgroundDownload.idle() : this(state: DownloadState.idle);

  final DownloadState state;
  final double progress;
  final String? path;
  final String? error;

  bool get isRunning => state == DownloadState.running;
  File? get file => path == null ? null : File(path!);
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks GitHub Releases for a newer build, downloads it, and hands it to
/// the platform installer.
///
/// The repository must be public: release assets on a private repository need
/// an access token, and shipping one inside the app would expose it to anyone
/// who unpacks the APK.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const repository = 'waozhrani-hue/my-tv';
  static const _channel = MethodChannel('com.mytv.my_tv/installer');
  static const _timeout = Duration(seconds: 25);

  final http.Client _client;

  /// The newest release if it is ahead of this build, otherwise null.
  Future<AppRelease?> check() async {
    final release = await latest();
    return isNewer(release.version, AppInfo.version) ? release : null;
  }

  Future<AppRelease> latest() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$repository/releases/latest',
    );

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'Accept': 'application/vnd.github+json'})
          .timeout(_timeout);
    } on TimeoutException {
      throw UpdateException('GitHub did not answer within 25 seconds.');
    } catch (e) {
      throw UpdateException('Could not reach GitHub — $e');
    }

    if (response.statusCode == 404) {
      throw UpdateException(
        'No release has been published for $repository yet.',
      );
    }
    if (response.statusCode == 403) {
      throw UpdateException(
        'GitHub is rate limiting this network. Try again in a few minutes.',
      );
    }
    if (response.statusCode != 200) {
      throw UpdateException('GitHub returned HTTP ${response.statusCode}.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw UpdateException('Unexpected response from GitHub.');
    }
    return parseRelease(data);
  }

  /// Picks the APK and the Windows installer out of a release payload.
  static AppRelease parseRelease(Map<String, dynamic> data) {
    final tag = (data['tag_name'] as String?)?.trim() ?? '';
    final assets = ((data['assets'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    Map<String, dynamic>? pick(bool Function(String name) test) {
      for (final asset in assets) {
        final name = (asset['name'] as String?)?.toLowerCase() ?? '';
        if (test(name)) return asset;
      }
      return null;
    }

    final apk = pick((n) => n.endsWith('.apk'));
    final win = pick((n) => n.endsWith('.exe'));

    return AppRelease(
      version: normalizeVersion(tag),
      tag: tag,
      pageUrl: (data['html_url'] as String?) ??
          'https://github.com/$repository/releases',
      notes: (data['body'] as String?)?.trim() ?? '',
      apkUrl: apk?['browser_download_url'] as String?,
      apkBytes: (apk?['size'] as num?)?.toInt(),
      windowsUrl: win?['browser_download_url'] as String?,
      windowsBytes: (win?['size'] as num?)?.toInt(),
    );
  }

  /// `v1.2.0` and `1.2.0+3` both become `1.2.0`.
  static String normalizeVersion(String raw) {
    var v = raw.trim();
    if (v.toLowerCase().startsWith('v')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus >= 0) v = v.substring(0, plus);
    return v.trim();
  }

  /// Compares dotted version numbers. A missing or unparsable part counts as
  /// zero, so `1.2` and `1.2.0` are equal rather than an error.
  static bool isNewer(String candidate, String current) {
    final a = _parts(candidate);
    final b = _parts(current);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _parts(String version) => normalizeVersion(version)
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  /// Streams the asset to a file, reporting 0..1 as it goes.
  Future<File> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final url = release.assetUrl;
    if (url == null) {
      throw UpdateException(
        'This release has no download for ${Platform.operatingSystem}.',
      );
    }

    final dir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
    if (!await dir.exists()) await dir.create(recursive: true);

    final name = Uri.parse(url).pathSegments.last;
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    // A half-finished file from a previous attempt must not be installed.
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request).timeout(_timeout);
    if (response.statusCode != 200) {
      throw UpdateException(
        'The download failed with HTTP ${response.statusCode}.',
      );
    }

    final total = response.contentLength ?? release.assetBytes ?? 0;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (total > 0 && received < total) {
      await partial.delete();
      throw UpdateException('The download ended early; please try again.');
    }

    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
    onProgress?.call(1);
    return target;
  }

  /// Opens the downloaded build. On Android this hands the APK to the system
  /// installer, which shows its own confirmation; on Windows it launches the
  /// setup program and leaves it to close the running app.
  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      if (!await canRequestInstalls()) {
        throw UpdateException(
          'Android needs permission to install apps from My TV. '
          'Allow it in the screen that opens, then try again.',
        );
      }
      await _channel.invokeMethod<bool>('installApk', {'path': file.path});
      return;
    }
    if (Platform.isWindows) {
      await Process.start(
        file.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    throw UpdateException(
      'Installing updates is not supported on ${Platform.operatingSystem}.',
    );
  }

  // --- Background download (Android) ---------------------------------------

  /// Hands the transfer to a foreground service, which keeps running while
  /// the app is in the background or closed and posts a progress
  /// notification. When it finishes, tapping that notification opens the
  /// installer without reopening the app.
  Future<void> startBackgroundDownload(AppRelease release) async {
    final url = release.apkUrl;
    if (url == null) {
      throw UpdateException('This release has no Android download.');
    }
    await _channel.invokeMethod<void>('requestNotificationPermission');
    await _channel.invokeMethod<bool>('startBackgroundDownload', {
      'url': url,
      'name': Uri.parse(url).pathSegments.last,
    });
  }

  /// What the service is doing, readable even after the app was killed and
  /// restarted mid-download.
  Future<BackgroundDownload> backgroundStatus() async {
    if (!Platform.isAndroid) return const BackgroundDownload.idle();
    try {
      final data = await _channel.invokeMapMethod<String, Object?>(
        'downloadStatus',
      );
      if (data == null) return const BackgroundDownload.idle();
      return BackgroundDownload(
        state: switch (data['state']) {
          'running' => DownloadState.running,
          'done' => DownloadState.done,
          'failed' => DownloadState.failed,
          _ => DownloadState.idle,
        },
        progress: ((data['progress'] as num?)?.toInt() ?? 0) / 100,
        path: data['path'] as String?,
        error: data['error'] as String?,
      );
    } on PlatformException {
      return const BackgroundDownload.idle();
    } on MissingPluginException {
      return const BackgroundDownload.idle();
    }
  }

  Future<void> clearBackgroundStatus() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearDownloadStatus');
    } on PlatformException {
      // Nothing to clear.
    }
  }

  Future<bool> canRequestInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('canRequestInstalls') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openInstallSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on PlatformException {
      // Nothing useful to do; the settings screen simply did not open.
    }
  }
}
