/// Pulls the server, username and password out of a provider link.
///
/// Typing three fields on a TV remote is slow and error-prone, but providers
/// hand out a single URL that already contains all three. Pasting that one
/// string is enough.
class XtreamLink {
  const XtreamLink({required this.origin, this.username, this.password});

  /// `scheme://host[:port]`, with any path and query removed.
  final String origin;
  final String? username;
  final String? password;

  /// True when all three fields were found, so nothing is left to type.
  bool get isComplete =>
      (username?.isNotEmpty ?? false) && (password?.isNotEmpty ?? false);

  /// Recognises the shapes providers actually hand out:
  ///
  /// - `http://host:port/get.php?username=U&password=P&type=m3u_plus`
  /// - `http://host:port/player_api.php?username=U&password=P`
  /// - `http://host:port/live/U/P/1234.ts`, and the movie and series forms
  /// - `http://host:port/U/P/1234`
  /// - a bare `host:port`, which yields the origin alone
  ///
  /// Returns null when there is no host to work with.
  static XtreamLink? parse(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;

    // A bare host, or one with a port, parses as a path without this.
    if (!value.contains('://')) value = 'http://$value';

    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;

    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

    // Query first: get.php and player_api.php both use it.
    final query = <String, String>{
      for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value,
    };
    final queryUser = _clean(query['username']);
    final queryPass = _clean(query['password']);
    if (queryUser != null && queryPass != null) {
      return XtreamLink(
        origin: origin,
        username: queryUser,
        password: queryPass,
      );
    }

    // Otherwise the stream path form, where the two segments after the kind
    // are the credentials.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    const kinds = {'live', 'movie', 'series'};
    if (segments.length >= 3 && kinds.contains(segments.first.toLowerCase())) {
      return XtreamLink(
        origin: origin,
        username: _clean(segments[1]),
        password: _clean(segments[2]),
      );
    }
    // Some panels drop the kind entirely: /USER/PASS/1234
    if (segments.length == 3 && _looksLikeId(segments[2])) {
      return XtreamLink(
        origin: origin,
        username: _clean(segments[0]),
        password: _clean(segments[1]),
      );
    }

    // Host only: still useful, the user types the rest.
    return XtreamLink(
      origin: origin,
      username: queryUser,
      password: queryPass,
    );
  }

  /// Whether [raw] carries credentials, used to decide if pasting into the
  /// server field should fill the other two.
  static bool hasCredentials(String raw) => parse(raw)?.isComplete ?? false;

  static String? _clean(String? value) {
    final v = value?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// A trailing stream id, with or without a container extension.
  static bool _looksLikeId(String segment) {
    final withoutExtension = segment.split('.').first;
    return withoutExtension.isNotEmpty &&
        int.tryParse(withoutExtension) != null;
  }
}
