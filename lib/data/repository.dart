import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'local_store.dart';
import 'm3u_parser.dart';
import 'models.dart';
import 'xtream_client.dart';

/// Raised when a playlist cannot be fetched or understood.
class PlaylistException implements Exception {
  PlaylistException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns a [PlaylistSource] into a [Catalog], going through the on-disk cache
/// so that launching the app does not wait on the network.
class Repository {
  Repository(this._store, {http.Client? client})
    : _client = client ?? http.Client();

  final LocalStore _store;
  final http.Client _client;

  /// How long a cached catalog is served before a refresh is attempted.
  static const cacheLifetime = Duration(hours: 12);
  static const _timeout = Duration(seconds: 45);

  Future<Catalog> load(
    PlaylistSource source,
    Settings settings, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _store.readCatalog(source.id);
      if (cached != null && !cached.isEmpty && _isFresh(cached)) return cached;
    }

    final Catalog catalog;
    try {
      catalog = switch (source.kind) {
        SourceKind.m3u => await _loadM3u(source, settings),
        SourceKind.xtream => await _loadXtream(source, settings),
      };
    } catch (_) {
      // Fall back to a stale cache rather than showing nothing at all.
      final cached = await _store.readCatalog(source.id);
      if (cached != null && !cached.isEmpty) return cached;
      rethrow;
    }

    if (catalog.isEmpty) {
      throw PlaylistException('The playlist loaded but contained no channels.');
    }
    await _store.writeCatalog(source.id, catalog);
    return catalog;
  }

  bool _isFresh(Catalog catalog) {
    final at = catalog.fetchedAt;
    return at != null && DateTime.now().difference(at) < cacheLifetime;
  }

  // --- M3U -----------------------------------------------------------------

  Future<Catalog> _loadM3u(PlaylistSource source, Settings settings) async {
    final location = source.url?.trim();
    if (location == null || location.isEmpty) {
      throw PlaylistException('This playlist has no address.');
    }

    final String text;
    if (source.isLocalFile) {
      final file = File(location);
      if (!await file.exists()) {
        throw PlaylistException('The file is no longer at $location.');
      }
      text = await file.readAsString();
    } else {
      text = await _fetchText(
        location,
        source.userAgent ?? settings.userAgent,
      );
    }

    if (!text.trimLeft().toUpperCase().startsWith('#EXTM3U') &&
        !text.contains('#EXTINF')) {
      throw PlaylistException(
        'That address did not return an M3U playlist.',
      );
    }

    final parsed = M3uParser.parse(text);
    return Catalog(
      live: parsed.live,
      movies: const [],
      epgUrl: source.epgUrl ?? parsed.epgUrl,
      fetchedAt: DateTime.now(),
    );
  }

  Future<String> _fetchText(String url, String userAgent) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw PlaylistException('"$url" is not a valid address.');
    }

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': userAgent, 'Accept': '*/*'})
          .timeout(_timeout);
    } on TimeoutException {
      throw PlaylistException('The server did not answer within 45 seconds.');
    } catch (e) {
      throw PlaylistException(unreachableHint(uri, e));
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw PlaylistException(
        'The server refused the request (HTTP ${response.statusCode}). '
        'The link may have expired or need a different User-Agent.',
      );
    }
    if (response.statusCode != 200) {
      throw PlaylistException(statusHint(uri, response.statusCode));
    }
    // Providers are inconsistent about charset headers; decode as UTF-8 and
    // tolerate stray bytes so one bad channel name cannot fail the load.
    return const Utf8Decoder(allowMalformed: true).convert(response.bodyBytes);
  }

  /// Turns a bare status code into something the user can act on.
  ///
  /// Many providers disable the raw M3U export to stop playlists being shared
  /// while leaving the Xtream API open, and answer `get.php` with a refusal —
  /// often a non-standard status such as 884. Without this, the user is left
  /// looking at a number with no idea that the same credentials would work in
  /// Xtream mode.
  static String statusHint(Uri uri, int status) {
    final isXtreamExport =
        uri.path.toLowerCase().endsWith('get.php') &&
        uri.queryParameters.containsKey('username');
    if (isXtreamExport) {
      return 'The server answered HTTP $status for this playlist link. '
          'Providers often block M3U export but still allow the Xtream Codes '
          'API — add this provider as an Xtream account instead, using '
          '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''} '
          'with the same username and password.';
    }
    return 'The server returned HTTP $status.';
  }

  /// A connection that never opened. IPTV servers very often run plain HTTP
  /// only, so an https:// address that cannot connect is worth calling out.
  static String unreachableHint(Uri uri, Object error) {
    if (uri.scheme == 'https') {
      return 'Could not reach ${uri.host} over HTTPS. Many IPTV servers serve '
          'plain HTTP only — try the same address with http:// instead.';
    }
    return 'Could not reach ${uri.host} — $error';
  }

  // --- Xtream --------------------------------------------------------------

  Future<Catalog> _loadXtream(PlaylistSource source, Settings settings) async {
    final host = source.host?.trim();
    final username = source.username?.trim();
    final password = source.password;
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      throw PlaylistException('This playlist is missing its server or username.');
    }

    final client = XtreamClient(
      host: host,
      username: username,
      password: password ?? '',
      userAgent: source.userAgent ?? settings.userAgent,
      client: _client,
    );

    await client.login();
    final live = await client.liveStreams(settings.liveContainer);
    // A panel without a VOD package simply returns nothing; that is not an
    // error, so movies are optional.
    List<MediaItem> movies;
    try {
      movies = await client.vodStreams();
    } on XtreamException {
      movies = const [];
    }

    return Catalog(
      live: live,
      movies: movies,
      epgUrl: source.epgUrl ?? '${client.origin}/xmltv.php'
          '?username=${Uri.encodeQueryComponent(username)}'
          '&password=${Uri.encodeQueryComponent(password ?? '')}',
      fetchedAt: DateTime.now(),
    );
  }

  /// Checks credentials before a source is saved, so the user finds out in the
  /// form rather than on the channel list.
  Future<XtreamAccount> verifyXtream(
    String host,
    String username,
    String password,
    String userAgent,
  ) async {
    final client = XtreamClient(
      host: host,
      username: username,
      password: password,
      userAgent: userAgent,
      client: _client,
    );
    return client.login();
  }
}
