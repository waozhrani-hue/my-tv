import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/models.dart';

/// Round-trips through a real encode/decode, because what is written to disk
/// is JSON text and not the maps themselves.
T _roundTrip<T>(Map<String, dynamic> json, T Function(Map<String, dynamic>) read) =>
    read(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

void main() {
  group('PlaylistSource', () {
    test('survives a JSON round trip for an Xtream source', () {
      const original = PlaylistSource(
        id: 'abc',
        name: 'Provider',
        kind: SourceKind.xtream,
        host: 'http://example.com:8080',
        username: 'user',
        password: 'pass',
        epgUrl: 'http://example.com/xmltv.php',
        userAgent: 'Custom/1.0',
      );

      final restored = _roundTrip(original.toJson(), PlaylistSource.fromJson);
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.kind, SourceKind.xtream);
      expect(restored.host, original.host);
      expect(restored.username, original.username);
      expect(restored.password, original.password);
      expect(restored.epgUrl, original.epgUrl);
      expect(restored.userAgent, original.userAgent);
    });

    test('survives a JSON round trip for a local file source', () {
      const original = PlaylistSource(
        id: 'xyz',
        name: 'Local',
        kind: SourceKind.m3u,
        url: r'C:\playlists\mine.m3u',
        isLocalFile: true,
      );

      final restored = _roundTrip(original.toJson(), PlaylistSource.fromJson);
      expect(restored.isLocalFile, isTrue);
      expect(restored.url, r'C:\playlists\mine.m3u');
    });

    test('falls back to an M3U source when the stored kind is unknown', () {
      final restored = PlaylistSource.fromJson({
        'id': 'a',
        'name': 'Legacy',
        'kind': 'something-removed',
      });
      expect(restored.kind, SourceKind.m3u);
    });

    test('copyWith leaves the id and kind alone', () {
      const original = PlaylistSource(
        id: 'keep',
        name: 'Before',
        kind: SourceKind.xtream,
      );
      final updated = original.copyWith(name: 'After');
      expect(updated.id, 'keep');
      expect(updated.kind, SourceKind.xtream);
      expect(updated.name, 'After');
    });
  });

  group('MediaItem', () {
    test('survives a JSON round trip including headers', () {
      const original = MediaItem(
        id: 'xt:live:1',
        name: 'Channel',
        url: 'http://example.com/1.ts',
        kind: MediaKind.live,
        logo: 'http://logo/1.png',
        group: 'News',
        tvgId: 'ch.1',
        httpHeaders: {'User-Agent': 'Custom/1.0'},
      );

      final restored = _roundTrip(original.toJson(), MediaItem.fromJson);
      expect(restored.id, original.id);
      expect(restored.url, original.url);
      expect(restored.kind, MediaKind.live);
      expect(restored.group, 'News');
      expect(restored.tvgId, 'ch.1');
      expect(restored.httpHeaders, {'User-Agent': 'Custom/1.0'});
    });

    test('an item saved without headers reads back as empty', () {
      const original = MediaItem(
        id: 'a',
        name: 'A',
        url: 'http://example.com/a.ts',
        kind: MediaKind.movie,
      );
      final restored = _roundTrip(original.toJson(), MediaItem.fromJson);
      expect(restored.httpHeaders, isEmpty);
      expect(restored.kind, MediaKind.movie);
    });
  });

  group('Catalog', () {
    const live = MediaItem(
      id: 'l1',
      name: 'Live One',
      url: 'http://example.com/l1.ts',
      kind: MediaKind.live,
      group: 'News',
    );
    const movie = MediaItem(
      id: 'm1',
      name: 'Movie One',
      url: 'http://example.com/m1.mp4',
      kind: MediaKind.movie,
      group: 'Action',
    );

    test('survives a JSON round trip with both lists', () {
      final original = Catalog(
        live: const [live],
        movies: const [movie],
        epgUrl: 'http://example.com/xmltv.php',
        fetchedAt: DateTime.utc(2026, 10, 23, 12),
      );

      final restored = _roundTrip(original.toJson(), Catalog.fromJson);
      expect(restored.live.single.id, 'l1');
      expect(restored.movies.single.id, 'm1');
      expect(restored.epgUrl, original.epgUrl);
      expect(restored.fetchedAt, DateTime.utc(2026, 10, 23, 12));
      expect(restored.total, 2);
    });

    test('groupsOf only reports groups for the requested kind', () {
      const catalog = Catalog(live: [live], movies: [movie]);
      expect(catalog.groupsOf(MediaKind.live), ['News']);
      expect(catalog.groupsOf(MediaKind.movie), ['Action']);
    });

    test('isEmpty reflects both lists', () {
      expect(const Catalog().isEmpty, isTrue);
      expect(const Catalog(movies: [movie]).isEmpty, isFalse);
    });
  });

  group('Settings', () {
    test('survives a JSON round trip', () {
      const original = Settings(
        liveContainer: LiveContainer.hls,
        userAgent: 'Custom/2.0',
        lastSourceId: 'src',
        lastPlayedId: 'xt:live:3',
        hardwareDecoding: false,
        bufferMegabytes: 64,
      );

      final restored = _roundTrip(original.toJson(), Settings.fromJson);
      expect(restored.liveContainer, LiveContainer.hls);
      expect(restored.userAgent, 'Custom/2.0');
      expect(restored.lastSourceId, 'src');
      expect(restored.lastPlayedId, 'xt:live:3');
      expect(restored.hardwareDecoding, isFalse);
      expect(restored.bufferMegabytes, 64);
    });

    test('an empty stored object yields the defaults', () {
      final restored = Settings.fromJson(const {});
      expect(restored.liveContainer, LiveContainer.ts);
      expect(restored.userAgent, Settings.defaultUserAgent);
      expect(restored.hardwareDecoding, isTrue);
      expect(restored.bufferMegabytes, 32);
    });

    test('container extensions match what panels expect', () {
      expect(LiveContainer.ts.extension, 'ts');
      expect(LiveContainer.hls.extension, 'm3u8');
    });
  });
}
