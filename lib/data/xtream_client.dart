import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Raised when a panel answers but rejects the request.
class XtreamException implements Exception {
  XtreamException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to an Xtream Codes panel over `player_api.php`.
class XtreamClient {
  XtreamClient({
    required String host,
    required this.username,
    required this.password,
    required this.userAgent,
    http.Client? client,
  }) : origin = normalizeHost(host),
       _client = client ?? http.Client();

  final String origin;
  final String username;
  final String password;
  final String userAgent;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  /// Accepts `host:port`, `http://host:port`, a trailing slash, or a full
  /// `player_api.php` URL, and returns a bare `scheme://host[:port]` origin.
  static String normalizeHost(String input) {
    var value = input.trim();
    if (value.isEmpty) return value;
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.parse(value);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  void close() => _client.close();

  Future<dynamic> _call(Map<String, String> extra) async {
    final uri = Uri.parse('$origin/player_api.php').replace(
      queryParameters: {
        'username': username,
        'password': password,
        ...extra,
      },
    );

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': userAgent, 'Accept': '*/*'})
          .timeout(_timeout);
    } on TimeoutException {
      throw XtreamException('The server did not answer within 30 seconds.');
    } catch (e) {
      // Panels very often listen on plain HTTP only, so an https:// address
      // that refuses to connect is usually just the wrong scheme.
      if (uri.scheme == 'https') {
        throw XtreamException(
          'Could not reach ${uri.host} over HTTPS. Most Xtream panels serve '
          'plain HTTP only — try http://${uri.host}'
          '${uri.hasPort ? ':${uri.port}' : ''} instead.',
        );
      }
      throw XtreamException('Could not reach $origin — $e');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw XtreamException('Rejected by the server — check the username and password.');
    }
    if (response.statusCode != 200) {
      throw XtreamException('The server returned HTTP ${response.statusCode}.');
    }

    final body = response.body.trim();
    if (body.isEmpty) throw XtreamException('The server returned an empty response.');
    try {
      return jsonDecode(body);
    } on FormatException {
      throw XtreamException(
        'The response was not valid JSON. This address may not be an Xtream panel.',
      );
    }
  }

  /// Verifies the credentials and returns what the panel reports about them.
  Future<XtreamAccount> login() async {
    final data = await _call(const {});
    if (data is! Map<String, dynamic>) {
      throw XtreamException('Unexpected response shape from the panel.');
    }
    final info = (data['user_info'] as Map?)?.cast<String, dynamic>();
    if (info == null) {
      throw XtreamException('The panel did not return account information.');
    }
    final auth = info['auth'];
    if (auth == 0 || auth == '0') {
      throw XtreamException('Login failed — the username or password is wrong.');
    }
    final status = (info['status'] as String?) ?? 'Unknown';
    if (status.toLowerCase() == 'expired') {
      throw XtreamException('This subscription has expired.');
    }
    if (status.toLowerCase() == 'banned') {
      throw XtreamException('This account is banned.');
    }

    final server = (data['server_info'] as Map?)?.cast<String, dynamic>();
    return XtreamAccount(
      username: (info['username'] as String?) ?? username,
      status: status,
      expiresAt: _epochToDate(info['exp_date']),
      maxConnections: _toInt(info['max_connections']),
      activeConnections: _toInt(info['active_cons']),
      serverName: server?['url'] as String?,
    );
  }

  /// Live channels, with their category names resolved.
  Future<List<MediaItem>> liveStreams(LiveContainer container) async {
    final categories = await _categories('get_live_categories');
    final rows = await _rows('get_live_streams');
    final out = <MediaItem>[];
    for (final row in rows) {
      final id = _toInt(row['stream_id']);
      final name = (row['name'] as String?)?.trim();
      if (id == null || name == null || name.isEmpty) continue;
      out.add(
        MediaItem(
          id: 'xt:live:$id',
          name: name,
          url: '$origin/live/${_seg(username)}/${_seg(password)}/$id.${container.extension}',
          kind: MediaKind.live,
          logo: _blankToNull(row['stream_icon'] as String?),
          group: categories[_categoryKey(row)] ?? 'Uncategorised',
          tvgId: _blankToNull(row['epg_channel_id'] as String?),
        ),
      );
    }
    return out;
  }

  /// On-demand movies. Each row carries its own container extension.
  Future<List<MediaItem>> vodStreams() async {
    final categories = await _categories('get_vod_categories');
    final rows = await _rows('get_vod_streams');
    final out = <MediaItem>[];
    for (final row in rows) {
      final id = _toInt(row['stream_id']);
      final name = (row['name'] as String?)?.trim();
      if (id == null || name == null || name.isEmpty) continue;
      final ext = _blankToNull(row['container_extension'] as String?) ?? 'mp4';
      out.add(
        MediaItem(
          id: 'xt:vod:$id',
          name: name,
          url: '$origin/movie/${_seg(username)}/${_seg(password)}/$id.$ext',
          kind: MediaKind.movie,
          logo: _blankToNull(row['stream_icon'] as String?),
          group: categories[_categoryKey(row)] ?? 'Uncategorised',
        ),
      );
    }
    return out;
  }

  Future<Map<String, String>> _categories(String action) async {
    try {
      final rows = await _rows(action);
      return {
        for (final row in rows)
          ?_blankToNull(row['category_id']?.toString()):
              _blankToNull(row['category_name'] as String?) ?? 'Uncategorised',
      };
    } on XtreamException {
      // Categories are a nicety; a panel that refuses them can still stream.
      return const {};
    }
  }

  Future<List<Map<String, dynamic>>> _rows(String action) async {
    final data = await _call({'action': action});
    if (data is List) return data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    // Some panels answer with {"error": "..."} or an empty object.
    if (data is Map && data['error'] != null) {
      throw XtreamException('The panel reported: ${data['error']}');
    }
    return const [];
  }

  static String? _categoryKey(Map<String, dynamic> row) =>
      _blankToNull(row['category_id']?.toString());

  static String _seg(String value) => Uri.encodeComponent(value);

  static String? _blankToNull(String? value) {
    final v = value?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static int? _toInt(Object? value) => switch (value) {
    int v => v,
    String v => int.tryParse(v.trim()),
    num v => v.toInt(),
    _ => null,
  };

  static DateTime? _epochToDate(Object? value) {
    final seconds = _toInt(value);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}
