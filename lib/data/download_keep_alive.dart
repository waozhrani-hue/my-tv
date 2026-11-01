import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the app alive while a download runs.
///
/// The transfer itself is plain Dart and works well, but Android is free to
/// kill a backgrounded process and take the download with it. A foreground
/// service makes the process ineligible for that, and its notification shows
/// the progress.
abstract interface class DownloadKeepAlive {
  Future<void> start(String title);
  Future<void> update(String title, int percent);
  Future<void> stop();

  /// The platform implementation where one applies, and a no-op elsewhere —
  /// desktop needs nothing, and tests should not reach a channel.
  factory DownloadKeepAlive.platform() =>
      !kIsWeb && Platform.isAndroid
          ? const _AndroidKeepAlive()
          : const NoDownloadKeepAlive();
}

/// Does nothing, for platforms that need nothing and for tests.
class NoDownloadKeepAlive implements DownloadKeepAlive {
  const NoDownloadKeepAlive();

  @override
  Future<void> start(String title) async {}

  @override
  Future<void> update(String title, int percent) async {}

  @override
  Future<void> stop() async {}
}

class _AndroidKeepAlive implements DownloadKeepAlive {
  const _AndroidKeepAlive();

  static const _channel = MethodChannel('com.mytv.my_tv/installer');

  @override
  Future<void> start(String title) => _send('keepAliveStart', title, -1);

  @override
  Future<void> update(String title, int percent) =>
      _send('keepAliveUpdate', title, percent);

  @override
  Future<void> stop() => _send('keepAliveStop', null, null);

  Future<void> _send(String method, String? title, int? percent) async {
    try {
      await _channel.invokeMethod<void>(method, {
        'title': ?title,
        'percent': ?percent,
      });
    } on PlatformException {
      // Losing the notification is survivable; the download carries on while
      // the app is open either way.
    } on MissingPluginException {
      // Running against a build without the service.
    }
  }
}
