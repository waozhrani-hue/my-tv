@Tags(['probe'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:my_tv/data/download_manager.dart';
import 'package:my_tv/data/local_store.dart';
import 'package:my_tv/data/models.dart';

/// A diagnostic that runs the real DownloadManager against a real URL.
///
/// Tagged `probe` and excluded from the normal run: it needs the network and
/// a live provider. Use it when downloads misbehave in the field and the
/// question is whether the fault is in this code or at the far end:
///
///   flutter test test/download_live_probe_test.dart --tags probe \
///     --dart-define=PROBE_URL=http://host/movie/user/pass/123.mkv
void main() {
  const url = String.fromEnvironment('PROBE_URL');

  test('raw package:http request, no DownloadManager involved', () async {
    if (url.isEmpty) {
      markTestSkipped('pass --dart-define=PROBE_URL=<movie url>');
      return;
    }
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = Settings.defaultUserAgent;
    try {
      final response = await client.send(request);
      // ignore: avoid_print
      print('RAW status=${response.statusCode} length=${response.contentLength}');
      // ignore: avoid_print
      print('RAW headers=${response.headers}');
    } catch (e) {
      // ignore: avoid_print
      print('RAW threw: $e');
    }
    client.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('downloads a real file through DownloadManager', () async {
    if (url.isEmpty) {
      markTestSkipped('pass --dart-define=PROBE_URL=<movie url>');
      return;
    }

    TestWidgetsFlutterBinding.ensureInitialized();
    // The test binding installs an HttpOverrides that answers every request
    // with 400 so tests cannot reach the network. This probe exists to reach
    // it, so that override has to go.
    HttpOverrides.global = null;
    final temp = await Directory.systemTemp.createTemp('my_tv_probe');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );

    final store = await LocalStore.openIn(temp);
    final manager = DownloadManager(store);
    await manager.load();

    final film = MediaItem(
      id: 'probe:1',
      name: 'Probe',
      url: url,
      kind: MediaKind.movie,
    );

    await manager.enqueue(film, userAgent: Settings.defaultUserAgent);

    // Watch it for a while and report what the manager actually does.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final record = manager.recordFor(film.id);
      if (record == null) {
        // ignore: avoid_print
        print('[${i}s] no record — enqueue refused it');
        break;
      }
      // ignore: avoid_print
      print(
        '[${i}s] state=${record.state.name} '
        'received=${record.receivedBytes} total=${record.totalBytes} '
        'error=${record.error ?? "-"}',
      );
      if (record.state == DownloadState.completed ||
          record.state == DownloadState.failed) {
        break;
      }
    }

    final record = manager.recordFor(film.id);
    // ignore: avoid_print
    print('final: ${record?.state.name} ${record?.error ?? ""}');
    // ignore: avoid_print
    print('bytes on disk: ${record == null ? 0 : record.receivedBytes}');

    manager.dispose();
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
