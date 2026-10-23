import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:my_tv/data/repository.dart';
import 'package:my_tv/data/xtream_client.dart';

/// These cover the messages a user actually hits when a provider misbehaves.
/// Both cases here were found against a live panel: an `https://` address on a
/// server with no TLS listener, and a `get.php` export answered with a
/// non-standard refusal status while the Xtream API kept working.
void main() {
  group('statusHint', () {
    final export = Uri.parse(
      'http://panel.example/get.php?username=u&password=p&type=m3u_plus',
    );

    test('points a blocked M3U export at Xtream mode', () {
      final message = Repository.statusHint(export, 884);
      expect(message, contains('884'));
      expect(message, contains('Xtream'));
      expect(message, contains('http://panel.example'));
    });

    test('keeps the port when the panel uses one', () {
      final message = Repository.statusHint(
        Uri.parse('http://panel.example:8080/get.php?username=u&password=p'),
        403,
      );
      expect(message, contains('http://panel.example:8080'));
    });

    test('stays plain for an ordinary playlist URL', () {
      final message = Repository.statusHint(
        Uri.parse('http://cdn.example/list.m3u'),
        500,
      );
      expect(message, 'The server returned HTTP 500.');
      expect(message, isNot(contains('Xtream')));
    });

    test('a get.php URL without credentials is not treated as an export', () {
      final message = Repository.statusHint(
        Uri.parse('http://cdn.example/get.php'),
        404,
      );
      expect(message, 'The server returned HTTP 404.');
    });
  });

  group('unreachableHint', () {
    test('suggests http when an https address will not connect', () {
      final message = Repository.unreachableHint(
        Uri.parse('https://panel.example/get.php'),
        Exception('connection refused'),
      );
      expect(message, contains('HTTPS'));
      expect(message, contains('http://'));
    });

    test('reports the underlying error for a plain http address', () {
      final message = Repository.unreachableHint(
        Uri.parse('http://panel.example/list.m3u'),
        Exception('boom'),
      );
      expect(message, contains('panel.example'));
      expect(message, contains('boom'));
      expect(message, isNot(contains('HTTPS')));
    });
  });

  group('XtreamClient scheme hint', () {
    test('an https panel that refuses to connect suggests http', () async {
      final client = XtreamClient(
        host: 'https://panel.example:443',
        username: 'u',
        password: 'p',
        userAgent: 'Test/1.0',
        client: MockClient((_) async => throw Exception('connection refused')),
      );

      await expectLater(
        client.login(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTPS'), contains('http://panel.example')),
          ),
        ),
      );
    });

    test('a plain http failure reports the origin as-is', () async {
      final client = XtreamClient(
        host: 'http://panel.example',
        username: 'u',
        password: 'p',
        userAgent: 'Test/1.0',
        client: MockClient((_) async => throw Exception('boom')),
      );

      await expectLater(
        client.login(),
        throwsA(
          isA<XtreamException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Could not reach'), isNot(contains('HTTPS'))),
          ),
        ),
      );
    });
  });
}
