import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/m3u_parser.dart';
import 'package:my_tv/data/models.dart';

void main() {
  group('M3uParser', () {
    test('reads attributes, title and guide URL', () {
      final catalog = M3uParser.parse('''
#EXTM3U url-tvg="http://guide.example/xmltv.xml"
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://logo/bbc1.png" group-title="UK",BBC One HD
http://stream.example/bbc1.m3u8
''');

      expect(catalog.epgUrl, 'http://guide.example/xmltv.xml');
      expect(catalog.live, hasLength(1));

      final channel = catalog.live.single;
      expect(channel.name, 'BBC One HD');
      expect(channel.tvgId, 'bbc1.uk');
      expect(channel.logo, 'http://logo/bbc1.png');
      expect(channel.group, 'UK');
      expect(channel.url, 'http://stream.example/bbc1.m3u8');
      expect(channel.kind, MediaKind.live);
    });

    test('falls back to #EXTGRP when group-title is absent', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1,Sports One
#EXTGRP:Sports
http://stream.example/sports1.ts
''');

      expect(catalog.live.single.group, 'Sports');
    });

    test('group-title wins over a later #EXTGRP', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1 group-title="News",Channel
#EXTGRP:Ignored
http://stream.example/a.ts
''');

      expect(catalog.live.single.group, 'News');
    });

    test('collects per-channel HTTP headers from #EXTVLCOPT', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1,Guarded
#EXTVLCOPT:http-user-agent=CustomAgent/2.0
#EXTVLCOPT:http-referrer=http://portal.example/
http://stream.example/guarded.ts
''');

      expect(catalog.live.single.httpHeaders, {
        'User-Agent': 'CustomAgent/2.0',
        'Referer': 'http://portal.example/',
      });
    });

    test('headers do not leak into the next channel', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1,With headers
#EXTVLCOPT:http-user-agent=CustomAgent/2.0
http://stream.example/a.ts
#EXTINF:-1,Without headers
http://stream.example/b.ts
''');

      expect(catalog.live[0].httpHeaders, isNotEmpty);
      expect(catalog.live[1].httpHeaders, isEmpty);
    });

    test('ignores unplayable URLs and unknown directives', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#KODIPROP:inputstream.adaptive.license_type=widevine
#EXTINF:-1,Good
http://stream.example/good.ts
#EXTINF:-1,Bad scheme
magnet:?xt=urn:btih:abc
#EXTINF:-1,Relative
/no/scheme/here.ts
''');

      expect(catalog.live.map((c) => c.name), ['Good']);
    });

    test('a bare URL with no preceding #EXTINF is skipped', () {
      final catalog = M3uParser.parse('''
#EXTM3U
http://stream.example/orphan.ts
''');

      expect(catalog.live, isEmpty);
    });

    test('ids are unique even when two channels share a tvg-id', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1 tvg-id="dup",First
http://stream.example/1.ts
#EXTINF:-1 tvg-id="dup",Second
http://stream.example/2.ts
''');

      final ids = catalog.live.map((c) => c.id).toSet();
      expect(ids, hasLength(2));
    });

    test('ids are stable across repeated parses of the same playlist', () {
      const text = '''
#EXTM3U
#EXTINF:-1,No Guide Id
http://stream.example/x.ts
''';

      expect(
        M3uParser.parse(text).live.single.id,
        M3uParser.parse(text).live.single.id,
      );
    });

    test('tolerates CRLF line endings and blank lines', () {
      final catalog = M3uParser.parse(
        '#EXTM3U\r\n\r\n#EXTINF:-1,Alpha\r\nhttp://stream.example/a.ts\r\n',
      );

      expect(catalog.live.single.name, 'Alpha');
    });

    test('uses tvg-name when the title after the comma is empty', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1 tvg-name="Fallback Name",
http://stream.example/a.ts
''');

      expect(catalog.live.single.name, 'Fallback Name');
    });

    test('groups are listed once, sorted, ignoring blanks', () {
      final catalog = M3uParser.parse('''
#EXTM3U
#EXTINF:-1 group-title="Sports",A
http://stream.example/a.ts
#EXTINF:-1 group-title="News",B
http://stream.example/b.ts
#EXTINF:-1 group-title="Sports",C
http://stream.example/c.ts
#EXTINF:-1,D
http://stream.example/d.ts
''');

      expect(catalog.groupsOf(MediaKind.live), ['News', 'Sports']);
    });

    test('an empty playlist yields an empty catalog', () {
      expect(M3uParser.parse('#EXTM3U\n').live, isEmpty);
      expect(M3uParser.parse('').live, isEmpty);
    });
  });
}
