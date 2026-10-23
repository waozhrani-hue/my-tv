import 'models.dart';

/// Parses extended M3U playlists into a [Catalog].
///
/// Handles the directives IPTV providers actually emit: `#EXTINF` with its
/// `tvg-*`/`group-title` attributes, `#EXTGRP` as a group fallback, and
/// `#EXTVLCOPT` for per-channel HTTP headers.
abstract final class M3uParser {
  static final _attribute = RegExp(r'([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"');

  static Catalog parse(String text) {
    final items = <MediaItem>[];
    final usedIds = <String, int>{};
    String? epgUrl;

    // Carried across lines until the URL that closes the current entry.
    String? name;
    String? logo;
    String? group;
    String? tvgId;
    var headers = <String, String>{};
    var sawExtInf = false;

    void reset() {
      name = null;
      logo = null;
      group = null;
      tvgId = null;
      headers = {};
      sawExtInf = false;
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        final upper = line.toUpperCase();

        if (upper.startsWith('#EXTM3U')) {
          final attrs = _attributes(line);
          epgUrl = attrs['url-tvg'] ?? attrs['x-tvg-url'] ?? epgUrl;
        } else if (upper.startsWith('#EXTINF')) {
          reset();
          sawExtInf = true;
          final comma = line.indexOf(',');
          final head = comma >= 0 ? line.substring(0, comma) : line;
          final attrs = _attributes(head);
          tvgId = _blankToNull(attrs['tvg-id']);
          logo = _blankToNull(attrs['tvg-logo']);
          group = _blankToNull(attrs['group-title']);
          final title = comma >= 0 ? line.substring(comma + 1).trim() : '';
          name = title.isNotEmpty
              ? title
              : _blankToNull(attrs['tvg-name']) ?? 'Unnamed';
        } else if (upper.startsWith('#EXTGRP')) {
          group ??= _blankToNull(line.substring(line.indexOf(':') + 1).trim());
        } else if (upper.startsWith('#EXTVLCOPT')) {
          final option = line.substring(line.indexOf(':') + 1);
          final eq = option.indexOf('=');
          if (eq > 0) {
            final key = option.substring(0, eq).trim().toLowerCase();
            final value = option.substring(eq + 1).trim();
            if (value.isEmpty) continue;
            switch (key) {
              case 'http-user-agent':
                headers['User-Agent'] = value;
              case 'http-referrer':
              case 'http-referer':
                headers['Referer'] = value;
              case 'http-origin':
                headers['Origin'] = value;
            }
          }
        }
        continue;
      }

      // A bare line closes the entry opened by the last #EXTINF.
      if (!sawExtInf) continue;
      final url = line;
      if (!_looksPlayable(url)) {
        reset();
        continue;
      }

      final channelName = (name ?? '').trim().isEmpty ? 'Unnamed' : name!.trim();
      final base = tvgId != null && tvgId!.isNotEmpty
          ? 'tvg:$tvgId'
          : 'm3u:${_stableHash('$channelName|$url')}';
      final seen = usedIds.update(base, (n) => n + 1, ifAbsent: () => 0);
      items.add(
        MediaItem(
          id: seen == 0 ? base : '$base#$seen',
          name: channelName,
          url: url,
          kind: MediaKind.live,
          logo: logo,
          group: group,
          tvgId: tvgId,
          httpHeaders: Map.unmodifiable(headers),
        ),
      );
      reset();
    }

    return Catalog(live: items, epgUrl: epgUrl, fetchedAt: DateTime.now());
  }

  static Map<String, String> _attributes(String line) {
    final out = <String, String>{};
    for (final m in _attribute.allMatches(line)) {
      out[m.group(1)!.toLowerCase()] = m.group(2)!;
    }
    return out;
  }

  static String? _blankToNull(String? value) {
    final v = value?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static bool _looksPlayable(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtmps://') ||
        lower.startsWith('rtsp://') ||
        lower.startsWith('udp://') ||
        lower.startsWith('rtp://') ||
        lower.startsWith('file://');
  }

  /// FNV-1a. Used instead of [Object.hashCode] so that ids — and therefore
  /// saved favourites — stay identical across runs and SDK upgrades.
  static String _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
      if (unit > 0xff) {
        hash ^= (unit >> 8) & 0xff;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
