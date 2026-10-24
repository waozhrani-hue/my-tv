import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_tv/data/download_manager.dart';
import 'package:my_tv/data/local_store.dart';
import 'package:my_tv/data/models.dart';

/// The point of a download is that it is on the device afterwards, so these
/// check the file as well as the record.
void main() {
  late Directory temp;
  late LocalStore store;

  const film = MediaItem(
    id: 'xt:vod:42',
    name: 'A Film',
    url: 'http://example.com/movie/u/p/42.mkv',
    kind: MediaKind.movie,
  );
  const channel = MediaItem(
    id: 'xt:live:1',
    name: 'A Channel',
    url: 'http://example.com/live/u/p/1.ts',
    kind: MediaKind.live,
  );

  final payload = Uint8List.fromList(List.generate(4096, (i) => i % 256));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('my_tv_dl');
    store = await LocalStore.openIn(temp);
    // path_provider has no host implementation, so point its channel at the
    // throwaway directory the manager will write under.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    // Windows holds a just-written file open for a moment after the sink
    // closes, so give the delete a few tries before letting it go.
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  });

  DownloadManager managerServing(Uint8List body, {int status = 200}) {
    final client = MockClient.streaming((request, bodyStream) async {
      if (status != 200) {
        return http.StreamedResponse(const Stream.empty(), status);
      }
      return http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
      );
    });
    return DownloadManager(store, client: client);
  }

  Future<void> settle(DownloadManager manager) async {
    for (var i = 0; i < 80; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (!manager.hasActive) return;
    }
  }

  test('a film is written to disk and marked complete', () async {
    final manager = managerServing(payload);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);

    final record = manager.recordFor(film.id)!;
    expect(record.state, DownloadState.completed);
    expect(record.totalBytes, payload.length);

    final path = manager.localPathFor(film.id);
    expect(path, isNotNull);
    expect(await File(path!).readAsBytes(), payload);
    // The partial file must not be left behind.
    expect(await File('${record.path}.part').exists(), isFalse);
    manager.dispose();
  });

  test('the saved file keeps the extension from the stream URL', () async {
    final manager = managerServing(payload);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);

    expect(manager.localPathFor(film.id), endsWith('.mkv'));
    manager.dispose();
  });

  test('live channels are refused — there is no end to download', () async {
    final manager = managerServing(payload);
    await manager.load();
    await manager.enqueue(channel, userAgent: 'Test/1.0');

    expect(manager.recordFor(channel.id), isNull);
    expect(manager.isEmpty, isTrue);
    manager.dispose();
  });

  test('a server error leaves the record failed, with a reason', () async {
    final manager = managerServing(payload, status: 500);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);

    final record = manager.recordFor(film.id)!;
    expect(record.state, DownloadState.failed);
    expect(record.error, contains('500'));
    expect(manager.localPathFor(film.id), isNull);
    manager.dispose();
  });

  test('a failed download can be retried', () async {
    final manager = managerServing(payload, status: 500);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);
    expect(manager.recordFor(film.id)!.state, DownloadState.failed);

    await manager.retry(film.id, userAgent: 'Test/1.0');
    await settle(manager);
    // Still failing, but it went back through the queue rather than sticking.
    expect(manager.recordFor(film.id)!.state, DownloadState.failed);
    manager.dispose();
  });

  test('removing a download deletes the file and the record', () async {
    final manager = managerServing(payload);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);

    final path = manager.localPathFor(film.id)!;
    await manager.remove(film.id);

    expect(manager.recordFor(film.id), isNull);
    expect(await File(path).exists(), isFalse);
    expect(await store.readDownloads(), isEmpty);
    manager.dispose();
  });

  test('enqueuing the same film twice does not duplicate it', () async {
    final manager = managerServing(payload);
    await manager.load();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);

    expect(manager.records, hasLength(1));
    manager.dispose();
  });

  test('downloads survive a restart', () async {
    final first = managerServing(payload);
    await first.load();
    await first.enqueue(film, userAgent: 'Test/1.0');
    await settle(first);
    first.dispose();

    final second = managerServing(payload);
    await second.load();
    expect(second.recordFor(film.id)?.state, DownloadState.completed);
    expect(second.localPathFor(film.id), isNotNull);
    second.dispose();
  });

  test('a record whose file has gone is dropped on load', () async {
    final first = managerServing(payload);
    await first.load();
    await first.enqueue(film, userAgent: 'Test/1.0');
    await settle(first);
    final path = first.localPathFor(film.id)!;
    first.dispose();

    // Someone cleared the app's storage from outside.
    await File(path).delete();

    final second = managerServing(payload);
    await second.load();
    expect(second.recordFor(film.id), isNull);
    second.dispose();
  });

  test('playback suspends downloading and resuming picks it back up', () async {
    final manager = managerServing(payload);
    await manager.load();

    // A provider that allows one connection cannot do both at once.
    manager.suspendForPlayback();
    expect(manager.isSuspended, isTrue);

    await manager.enqueue(film, userAgent: 'Test/1.0');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      manager.recordFor(film.id)!.state,
      DownloadState.queued,
      reason: 'nothing may transfer while something is playing',
    );
    expect(manager.localPathFor(film.id), isNull);

    manager.resumeAfterPlayback();
    expect(manager.isSuspended, isFalse);
    await settle(manager);

    expect(manager.recordFor(film.id)!.state, DownloadState.completed);
    manager.dispose();
  });

  test('a suspended download is queued, not failed', () async {
    final manager = managerServing(payload);
    await manager.load();
    manager.suspendForPlayback();
    await manager.enqueue(film, userAgent: 'Test/1.0');
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final record = manager.recordFor(film.id)!;
    expect(record.state, DownloadState.queued);
    expect(record.error, isNull, reason: 'a pause is not an error');
    manager.dispose();
  });

  test('bytesOnDisk counts only what finished', () async {
    final manager = managerServing(payload);
    await manager.load();
    expect(manager.bytesOnDisk, 0);

    await manager.enqueue(film, userAgent: 'Test/1.0');
    await settle(manager);
    expect(manager.bytesOnDisk, payload.length);
    manager.dispose();
  });
}
