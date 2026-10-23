import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/local_store.dart';
import 'package:my_tv/data/models.dart';

/// Cover for data that went missing across app updates.
///
/// Two causes: the write replaced a file by deleting it and then renaming the
/// temporary one over it, which left a window with no file at all — and
/// installing an update kills the process, which is exactly when that window
/// is most likely to be hit. And a read that failed returned "no data", which
/// the next write then made permanent.
void main() {
  late Directory temp;
  late LocalStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('my_tv_store');
    store = await LocalStore.openIn(temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File dataFile(String name) =>
      File('${temp.path}${Platform.pathSeparator}data'
          '${Platform.pathSeparator}$name');

  const one = MediaItem(
    id: 'xt:live:1',
    name: 'Channel One',
    url: 'http://example.com/1.ts',
    kind: MediaKind.live,
    group: 'News',
  );
  const two = MediaItem(
    id: 'xt:live:2',
    name: 'Channel Two',
    url: 'http://example.com/2.ts',
    kind: MediaKind.live,
  );

  group('favourites', () {
    test('survive a write and read as whole items', () async {
      await store.writeFavorites([one, two]);

      final restored = await store.readFavorites();
      expect(restored.map((e) => e.id), ['xt:live:1', 'xt:live:2']);
      // The name and URL come back too, so the list can be shown and played
      // without a catalog loaded.
      expect(restored.first.name, 'Channel One');
      expect(restored.first.url, 'http://example.com/1.ts');
      expect(restored.first.group, 'News');
    });

    test('entries saved as bare ids are kept, not dropped', () async {
      // The pre-1.4 on-disk format.
      await dataFile('favorites.json').create(recursive: true);
      await dataFile('favorites.json')
          .writeAsString(jsonEncode(['xt:live:7', 'xt:live:8']));

      final restored = await store.readFavorites();
      expect(restored.map((e) => e.id), ['xt:live:7', 'xt:live:8']);
      // No URL, so they are not offered for playback until a catalog fills
      // them in.
      expect(restored.every((e) => e.isPlayable), isFalse);
    });

    test('a corrupt file falls back to the previous good copy', () async {
      await store.writeFavorites([one]);
      // A second write leaves the first as the backup.
      await store.writeFavorites([one, two]);

      await dataFile('favorites.json').writeAsString('{ this is not json');

      final restored = await store.readFavorites();
      expect(restored, isNotEmpty, reason: 'must not read as empty');
      expect(restored.map((e) => e.id), contains('xt:live:1'));
    });

    test('a file lost entirely falls back to the backup', () async {
      await store.writeFavorites([one]);
      await store.writeFavorites([one, two]);

      await dataFile('favorites.json').delete();

      final restored = await store.readFavorites();
      expect(restored, isNotEmpty);
    });

    test('an empty file does not read as an empty list', () async {
      await store.writeFavorites([one]);
      await store.writeFavorites([one, two]);

      await dataFile('favorites.json').writeAsString('   ');

      expect(await store.readFavorites(), isNotEmpty);
    });

    test('writing genuinely empty favourites is honoured', () async {
      await store.writeFavorites([one]);
      await store.writeFavorites([]);
      expect(await store.readFavorites(), isEmpty);
    });

    test('a backup is kept beside the file once it is replaced', () async {
      await store.writeFavorites([one]);
      await store.writeFavorites([one, two]);
      expect(await dataFile('favorites.json.bak').exists(), isTrue);
    });
  });

  group('history', () {
    test('survives a write and keeps its order', () async {
      await store.writeRecents([two, one]);
      final restored = await store.readRecents();
      expect(restored.map((e) => e.id), ['xt:live:2', 'xt:live:1']);
      expect(restored.first.name, 'Channel Two');
    });

    test('falls back to the backup when the file is corrupt', () async {
      await store.writeRecents([one]);
      await store.writeRecents([one, two]);
      await dataFile('recents.json').writeAsString('nonsense');
      expect(await store.readRecents(), isNotEmpty);
    });
  });

  group('other records', () {
    test('sources survive a round trip', () async {
      await store.writeSources(const [
        PlaylistSource(
          id: 'a',
          name: 'Provider',
          kind: SourceKind.xtream,
          host: 'http://example.com',
          username: 'u',
          password: 'p',
        ),
      ]);
      final restored = await store.readSources();
      expect(restored.single.name, 'Provider');
      expect(restored.single.username, 'u');
    });

    test('watch progress survives a round trip', () async {
      await store.writeProgress({
        'xt:vod:5': const WatchProgress(
          position: Duration(minutes: 12),
          duration: Duration(hours: 2),
        ),
      });
      final restored = await store.readProgress();
      expect(restored['xt:vod:5']?.position, const Duration(minutes: 12));
    });

    test('settings fall back to the backup when corrupt', () async {
      await store.writeSettings(const Settings(bufferMegabytes: 64));
      await store.writeSettings(const Settings(bufferMegabytes: 96));
      await dataFile('settings.json').writeAsString('broken');
      expect((await store.readSettings()).bufferMegabytes, 64);
    });

    test('reading from an empty store gives empty results, not an error', () async {
      expect(await store.readFavorites(), isEmpty);
      expect(await store.readRecents(), isEmpty);
      expect(await store.readSources(), isEmpty);
      expect(await store.readProgress(), isEmpty);
    });
  });
}
