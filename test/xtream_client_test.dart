import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_tv/data/models.dart';
import 'package:my_tv/data/xtream_client.dart';

/// Answers the handful of `player_api.php` actions the client uses.
MockClient _panel({
  Map<String, dynamic>? login,
  List<Map<String, dynamic>>? liveCategories,
  List<Map<String, dynamic>>? liveStreams,
  List<Map<String, dynamic>>? vodCategories,
  List<Map<String, dynamic>>? vodStreams,
  int status = 200,
}) {
  return MockClient((request) async {
    if (status != 200) return http.Response('nope', status);
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => login ??
          {
            'user_info': {'auth': 1, 'username': 'u', 'status': 'Active'},
            'server_info': {'url': 'example.com'},
          },
      'get_live_categories' => liveCategories ?? const [],
      'get_live_streams' => liveStreams ?? const [],
      'get_vod_categories' => vodCategories ?? const [],
      'get_vod_streams' => vodStreams ?? const [],
      _ => const [],
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

XtreamClient _client(http.Client inner) => XtreamClient(
  host: 'example.com:8080',
  username: 'user',
  password: 'pass',
  userAgent: 'Test/1.0',
  client: inner,
);

void main() {
  group('normalizeHost', () {
    test('adds a scheme when none is given', () {
      expect(
        XtreamClient.normalizeHost('example.com:8080'),
        'http://example.com:8080',
      );
    });

    test('drops a trailing slash and any path', () {
      expect(
        XtreamClient.normalizeHost('http://example.com:8080/'),
        'http://example.com:8080',
      );
      expect(
        XtreamClient.normalizeHost('http://example.com:8080/player_api.php'),
        'http://example.com:8080',
      );
    });

    test('keeps https and an absent port', () {
      expect(
        XtreamClient.normalizeHost('https://example.com'),
        'https://example.com',
      );
    });
  });

  group('login', () {
    test('returns the account on success', () async {
      final client = _client(
        _panel(
          login: {
            'user_info': {
              'auth': 1,
              'username': 'user',
              'status': 'Active',
              'exp_date': '1767225600',
              'max_connections': '2',
              'active_cons': '1',
            },
            'server_info': {'url': 'example.com'},
          },
        ),
      );

      final account = await client.login();
      expect(account.username, 'user');
      expect(account.status, 'Active');
      expect(account.maxConnections, 2);
      expect(account.activeConnections, 1);
      expect(account.expiresAt, isNotNull);
    });

    test('rejects auth = 0', () async {
      final client = _client(
        _panel(login: {'user_info': {'auth': 0}}),
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            contains('username or password'),
          ),
        ),
      );
    });

    test('reports an expired subscription', () async {
      final client = _client(
        _panel(
          login: {
            'user_info': {'auth': 1, 'username': 'user', 'status': 'Expired'},
          },
        ),
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            contains('expired'),
          ),
        ),
      );
    });

    test('explains a non-JSON response', () async {
      final client = XtreamClient(
        host: 'example.com',
        username: 'user',
        password: 'pass',
        userAgent: 'Test/1.0',
        client: MockClient((_) async => http.Response('<html>hi</html>', 200)),
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test('surfaces an HTTP 403 as a credentials problem', () async {
      final client = _client(_panel(status: 403));
      await expectLater(
        client.login(),
        throwsA(isA<XtreamException>()),
      );
    });
  });

  group('liveStreams', () {
    test('builds stream URLs and resolves category names', () async {
      final client = _client(
        _panel(
          liveCategories: [
            {'category_id': '7', 'category_name': 'Sports'},
          ],
          liveStreams: [
            {
              'stream_id': 101,
              'name': 'Sport HD',
              'stream_icon': 'http://logo/sport.png',
              'epg_channel_id': 'sport.hd',
              'category_id': '7',
            },
          ],
        ),
      );

      final live = await client.liveStreams(LiveContainer.ts);
      expect(live, hasLength(1));

      final channel = live.single;
      expect(channel.id, 'xt:live:101');
      expect(channel.name, 'Sport HD');
      expect(channel.url, 'http://example.com:8080/live/user/pass/101.ts');
      expect(channel.group, 'Sports');
      expect(channel.tvgId, 'sport.hd');
      expect(channel.kind, MediaKind.live);
    });

    test('honours the HLS container setting', () async {
      final client = _client(
        _panel(
          liveStreams: [
            {'stream_id': 5, 'name': 'A', 'category_id': '1'},
          ],
        ),
      );

      final live = await client.liveStreams(LiveContainer.hls);
      expect(live.single.url, endsWith('/5.m3u8'));
    });

    test('labels streams whose category is unknown', () async {
      final client = _client(
        _panel(
          liveCategories: [
            {'category_id': '1', 'category_name': 'Known'},
          ],
          liveStreams: [
            {'stream_id': 9, 'name': 'Orphan', 'category_id': '99'},
          ],
        ),
      );

      expect(
        (await client.liveStreams(LiveContainer.ts)).single.group,
        'Uncategorised',
      );
    });

    test('skips rows without a usable id or name', () async {
      final client = _client(
        _panel(
          liveStreams: [
            {'stream_id': 1, 'name': 'Fine', 'category_id': '1'},
            {'stream_id': null, 'name': 'No id', 'category_id': '1'},
            {'stream_id': 3, 'name': '  ', 'category_id': '1'},
          ],
        ),
      );

      expect(
        (await client.liveStreams(LiveContainer.ts)).map((c) => c.name),
        ['Fine'],
      );
    });

    test('percent-encodes credentials in the stream path', () async {
      final client = XtreamClient(
        host: 'example.com',
        username: 'a b',
        password: 'p/w',
        userAgent: 'Test/1.0',
        client: _panel(
          liveStreams: [
            {'stream_id': 4, 'name': 'Enc', 'category_id': '1'},
          ],
        ),
      );

      expect(
        (await client.liveStreams(LiveContainer.ts)).single.url,
        'http://example.com/live/a%20b/p%2Fw/4.ts',
      );
    });
  });

  group('vodStreams', () {
    test('uses each row container extension', () async {
      final client = _client(
        _panel(
          vodCategories: [
            {'category_id': '2', 'category_name': 'Action'},
          ],
          vodStreams: [
            {
              'stream_id': 55,
              'name': 'A Movie',
              'container_extension': 'mkv',
              'category_id': '2',
            },
            {'stream_id': 56, 'name': 'No Ext', 'category_id': '2'},
          ],
        ),
      );

      final movies = await client.vodStreams();
      expect(movies[0].url, 'http://example.com:8080/movie/user/pass/55.mkv');
      expect(movies[0].kind, MediaKind.movie);
      expect(movies[0].group, 'Action');
      // Defaults to mp4 when the panel omits the container.
      expect(movies[1].url, endsWith('/56.mp4'));
    });
  });
}
