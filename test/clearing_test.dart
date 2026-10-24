import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_tv/data/local_store.dart';
import 'package:my_tv/data/models.dart';
import 'package:my_tv/data/repository.dart';
import 'package:my_tv/data/update_service.dart';
import 'package:my_tv/state/app_state.dart';

/// Clearing has to reach the disk, not just the screen: the whole point is
/// that the entries are gone after a restart.
void main() {
  late Directory temp;
  late LocalStore store;
  late AppState state;

  const one = MediaItem(
    id: 'xt:live:1',
    name: 'Channel One',
    url: 'http://example.com/1.ts',
    kind: MediaKind.live,
  );
  const two = MediaItem(
    id: 'xt:live:2',
    name: 'Channel Two',
    url: 'http://example.com/2.ts',
    kind: MediaKind.live,
  );
  const film = MediaItem(
    id: 'xt:vod:9',
    name: 'A Film',
    url: 'http://example.com/9.mp4',
    kind: MediaKind.movie,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('my_tv_clear');
    store = await LocalStore.openIn(temp);
    final client = MockClient(
      (_) async => http.Response('{}', 404),
    );
    state = AppState(
      store,
      Repository(store, client: client),
      updates: UpdateService(client: client),
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A second AppState over the same directory, standing in for a restart.
  Future<AppState> reopened() async {
    final reopenedStore = await LocalStore.openIn(temp);
    final client = MockClient((_) async => http.Response('{}', 404));
    final next = AppState(
      reopenedStore,
      Repository(reopenedStore, client: client),
      updates: UpdateService(client: client),
    );
    await next.bootstrap();
    return next;
  }

  group('watch history', () {
    test('clearing empties it and survives a restart', () async {
      await state.noteWatched(one);
      await state.noteWatched(two);
      expect(state.recentCount, 2);

      await state.clearRecents();
      expect(state.recentCount, 0);
      expect(await store.readRecents(), isEmpty);
      expect((await reopened()).recentCount, 0);
    });

    test('a single entry can be dropped, leaving the rest', () async {
      await state.noteWatched(one);
      await state.noteWatched(two);

      await state.removeRecent(one.id);
      expect(state.recentCount, 1);
      expect((await store.readRecents()).single.id, two.id);
    });

    test('removing something not in the history changes nothing', () async {
      await state.noteWatched(one);
      await state.removeRecent('nothing-like-this');
      expect(state.recentCount, 1);
    });

    test('clearing an empty history is harmless', () async {
      await state.clearRecents();
      expect(state.recentCount, 0);
    });

    test('clearing the history keeps favourites and film positions', () async {
      await state.toggleFavorite(one);
      await state.saveProgress(
        film,
        const Duration(minutes: 10),
        const Duration(hours: 2),
      );
      await state.noteWatched(two);

      await state.clearRecents();

      expect(state.recentCount, 0);
      expect(state.favoriteCount, 1, reason: 'favourites are separate');
      expect(state.progressCount, 1, reason: 'film positions are separate');
    });
  });

  group('film positions', () {
    test('clearing them empties the list and survives a restart', () async {
      await state.saveProgress(
        film,
        const Duration(minutes: 10),
        const Duration(hours: 2),
      );
      expect(state.progressCount, 1);

      await state.clearAllProgress();
      expect(state.progressCount, 0);
      expect(await store.readProgress(), isEmpty);
      expect((await reopened()).progressCount, 0);
    });

    test('a cleared film has nothing to resume', () async {
      await state.saveProgress(
        film,
        const Duration(minutes: 10),
        const Duration(hours: 2),
      );
      expect(state.progressFor(film.id), isNotNull);

      await state.clearAllProgress();
      expect(state.progressFor(film.id), isNull);
    });
  });

  group('favourites', () {
    test('clearing them empties the list and survives a restart', () async {
      await state.toggleFavorite(one);
      await state.toggleFavorite(two);
      expect(state.favoriteCount, 2);

      await state.clearFavorites();
      expect(state.favoriteCount, 0);
      expect(state.isFavorite(one.id), isFalse);
      expect(await store.readFavorites(), isEmpty);
      expect((await reopened()).favoriteCount, 0);
    });

    test('clearing favourites keeps the history', () async {
      await state.toggleFavorite(one);
      await state.noteWatched(two);

      await state.clearFavorites();

      expect(state.favoriteCount, 0);
      expect(state.recentCount, 1);
    });
  });
}
