import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/xtream_link.dart';

void main() {
  group('parse — query forms', () {
    test('reads a get.php export link', () {
      final link = XtreamLink.parse(
        'http://example.com:8080/get.php'
        '?username=90dd02e15723&password=48cad1623b&type=m3u_plus&output=ts',
      );
      expect(link, isNotNull);
      expect(link!.origin, 'http://example.com:8080');
      expect(link.username, '90dd02e15723');
      expect(link.password, '48cad1623b');
      expect(link.isComplete, isTrue);
    });

    test('reads a player_api.php link', () {
      final link = XtreamLink.parse(
        'http://example.com/player_api.php?username=u&password=p',
      );
      expect(link!.origin, 'http://example.com');
      expect(link.username, 'u');
      expect(link.password, 'p');
    });

    test('parameter names are matched case-insensitively', () {
      final link = XtreamLink.parse(
        'http://example.com/get.php?Username=u&PASSWORD=p',
      );
      expect(link!.username, 'u');
      expect(link.password, 'p');
    });

    test('keeps https and a non-default port', () {
      final link = XtreamLink.parse(
        'https://example.com:2096/get.php?username=u&password=p',
      );
      expect(link!.origin, 'https://example.com:2096');
    });
  });

  group('parse — stream path forms', () {
    test('reads credentials out of a live stream URL', () {
      final link = XtreamLink.parse(
        'http://example.com:8080/live/myuser/mypass/1234.ts',
      );
      expect(link!.origin, 'http://example.com:8080');
      expect(link.username, 'myuser');
      expect(link.password, 'mypass');
    });

    test('handles the movie and series forms too', () {
      for (final kind in ['movie', 'series']) {
        final link = XtreamLink.parse('http://example.com/$kind/u/p/55.mkv');
        expect(link!.username, 'u', reason: kind);
        expect(link.password, 'p', reason: kind);
      }
    });

    test('handles a panel that omits the kind segment', () {
      final link = XtreamLink.parse('http://example.com:8080/myuser/mypass/9');
      expect(link!.username, 'myuser');
      expect(link.password, 'mypass');
    });

    test('a three-segment path that is not a stream is left alone', () {
      final link = XtreamLink.parse('http://example.com/some/other/page');
      expect(link!.origin, 'http://example.com');
      expect(link.isComplete, isFalse);
    });
  });

  group('parse — plain hosts', () {
    test('a bare host becomes an origin with no credentials', () {
      final link = XtreamLink.parse('example.com:8080');
      expect(link!.origin, 'http://example.com:8080');
      expect(link.isComplete, isFalse);
    });

    test('a host that already has a scheme is unchanged', () {
      expect(XtreamLink.parse('http://example.com')!.origin,
          'http://example.com');
    });

    test('surrounding whitespace is ignored', () {
      final link = XtreamLink.parse(
        '  http://example.com/get.php?username=u&password=p  ',
      );
      expect(link!.isComplete, isTrue);
    });
  });

  group('parse — rejections', () {
    test('empty input gives null', () {
      expect(XtreamLink.parse(''), isNull);
      expect(XtreamLink.parse('    '), isNull);
    });

    test('something with no host gives null', () {
      expect(XtreamLink.parse('/just/a/path'), isNull);
    });
  });

  group('hasCredentials', () {
    test('is true only when both parts are present', () {
      expect(
        XtreamLink.hasCredentials(
          'http://example.com/get.php?username=u&password=p',
        ),
        isTrue,
      );
      expect(XtreamLink.hasCredentials('http://example.com'), isFalse);
      expect(
        XtreamLink.hasCredentials('http://example.com/get.php?username=u'),
        isFalse,
        reason: 'half a credential pair is not enough to split a field',
      );
      expect(XtreamLink.hasCredentials('example.com:8080'), isFalse);
      expect(XtreamLink.hasCredentials(''), isFalse);
    });
  });
}
