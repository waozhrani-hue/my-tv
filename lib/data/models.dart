/// Core data model: playlist sources and the media they expose.
library;

/// How a playlist is obtained.
enum SourceKind {
  /// A plain M3U/M3U8 playlist, either over HTTP or from a local file.
  m3u,

  /// An Xtream Codes panel, queried through `player_api.php`.
  xtream,
}

/// Whether an item is a live channel or an on-demand title. Live items have no
/// meaningful duration, so the player hides the seek bar for them.
enum MediaKind { live, movie }

/// How the browse screen lays items out. Channels read better as a dense list,
/// films as posters, but which one is wanted differs per person and per
/// playlist, so it is a setting rather than a rule.
enum ViewMode {
  list,
  grid;

  ViewMode get other => this == ViewMode.list ? ViewMode.grid : ViewMode.list;
}

/// The container used when building Xtream live URLs. Panels differ in which
/// one they serve reliably, so this is user-switchable.
enum LiveContainer {
  ts,
  hls;

  String get extension => this == LiveContainer.ts ? 'ts' : 'm3u8';
  String get label => this == LiveContainer.ts ? 'MPEG-TS (.ts)' : 'HLS (.m3u8)';
}

/// A configured playlist. One app can hold several and switch between them.
class PlaylistSource {
  const PlaylistSource({
    required this.id,
    required this.name,
    required this.kind,
    this.url,
    this.isLocalFile = false,
    this.host,
    this.username,
    this.password,
    this.epgUrl,
    this.userAgent,
  });

  final String id;
  final String name;
  final SourceKind kind;

  /// M3U only: the playlist URL, or an absolute path when [isLocalFile].
  final String? url;
  final bool isLocalFile;

  /// Xtream only: panel origin (`http://host:port`) and credentials.
  final String? host;
  final String? username;
  final String? password;

  /// Optional XMLTV guide URL, used for the channel guide.
  final String? epgUrl;

  /// Sent as `User-Agent` on both playlist and stream requests. Some providers
  /// reject the default Dart agent.
  final String? userAgent;

  PlaylistSource copyWith({
    String? name,
    String? url,
    bool? isLocalFile,
    String? host,
    String? username,
    String? password,
    String? epgUrl,
    String? userAgent,
  }) {
    return PlaylistSource(
      id: id,
      name: name ?? this.name,
      kind: kind,
      url: url ?? this.url,
      isLocalFile: isLocalFile ?? this.isLocalFile,
      host: host ?? this.host,
      username: username ?? this.username,
      password: password ?? this.password,
      epgUrl: epgUrl ?? this.epgUrl,
      userAgent: userAgent ?? this.userAgent,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'url': url,
    'isLocalFile': isLocalFile,
    'host': host,
    'username': username,
    'password': password,
    'epgUrl': epgUrl,
    'userAgent': userAgent,
  };

  static PlaylistSource fromJson(Map<String, dynamic> json) {
    return PlaylistSource(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Playlist',
      kind: SourceKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => SourceKind.m3u,
      ),
      url: json['url'] as String?,
      isLocalFile: json['isLocalFile'] as bool? ?? false,
      host: json['host'] as String?,
      username: json['username'] as String?,
      password: json['password'] as String?,
      epgUrl: json['epgUrl'] as String?,
      userAgent: json['userAgent'] as String?,
    );
  }
}

/// A single playable entry: one live channel or one movie.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.url,
    required this.kind,
    this.logo,
    this.group,
    this.tvgId,
    this.httpHeaders = const {},
  });

  /// Stable across reloads of the same playlist, so favourites survive a
  /// refresh. Derived from the provider's own id when there is one.
  final String id;
  final String name;
  final String url;
  final MediaKind kind;
  final String? logo;
  final String? group;

  /// XMLTV channel id, used to match guide data.
  final String? tvgId;

  /// Per-item headers (`User-Agent`, `Referer`) parsed from `#EXTVLCOPT`.
  final Map<String, String> httpHeaders;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'kind': kind.name,
    'logo': logo,
    'group': group,
    'tvgId': tvgId,
    if (httpHeaders.isNotEmpty) 'httpHeaders': httpHeaders,
  };

  static MediaItem fromJson(Map<String, dynamic> json) {
    return MediaItem(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      kind: MediaKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => MediaKind.live,
      ),
      logo: json['logo'] as String?,
      group: json['group'] as String?,
      tvgId: json['tvgId'] as String?,
      httpHeaders:
          (json['httpHeaders'] as Map?)?.cast<String, String>() ?? const {},
    );
  }
}

/// Everything a source exposes, after parsing.
class Catalog {
  const Catalog({
    this.live = const [],
    this.movies = const [],
    this.epgUrl,
    this.fetchedAt,
  });

  final List<MediaItem> live;
  final List<MediaItem> movies;

  /// Guide URL advertised by the playlist (`url-tvg`) or configured by hand.
  final String? epgUrl;
  final DateTime? fetchedAt;

  bool get isEmpty => live.isEmpty && movies.isEmpty;
  int get total => live.length + movies.length;

  /// Distinct group names in playlist order, for the category sidebar.
  List<String> groupsOf(MediaKind kind) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in kind == MediaKind.live ? live : movies) {
      final g = (item.group ?? '').trim();
      if (g.isEmpty || !seen.add(g)) continue;
      out.add(g);
    }
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  Map<String, dynamic> toJson() => {
    'live': live.map((e) => e.toJson()).toList(),
    'movies': movies.map((e) => e.toJson()).toList(),
    'epgUrl': epgUrl,
    'fetchedAt': fetchedAt?.toIso8601String(),
  };

  static Catalog fromJson(Map<String, dynamic> json) {
    List<MediaItem> read(String key) =>
        ((json[key] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(MediaItem.fromJson)
            .toList();
    return Catalog(
      live: read('live'),
      movies: read('movies'),
      epgUrl: json['epgUrl'] as String?,
      fetchedAt: DateTime.tryParse(json['fetchedAt'] as String? ?? ''),
    );
  }
}

/// App-wide preferences.
class Settings {
  const Settings({
    this.liveContainer = LiveContainer.ts,
    this.userAgent = defaultUserAgent,
    this.lastSourceId,
    this.lastPlayedId,
    this.hardwareDecoding = true,
    this.bufferMegabytes = 32,
    this.liveView = ViewMode.list,
    this.movieView = ViewMode.grid,
    this.resumePlayback = true,
    this.skipSeconds = 10,
  });

  /// Offered in the settings screen for the double-tap skip.
  static const skipChoices = [5, 10, 15, 30];

  /// Many providers key off a known player agent; this is the common default.
  static const defaultUserAgent =
      'VLC/3.0.20 LibVLC/3.0.20';

  final LiveContainer liveContainer;
  final String userAgent;
  final String? lastSourceId;
  final String? lastPlayedId;
  final bool hardwareDecoding;
  final int bufferMegabytes;

  /// Layout chosen per section, so channels and films can differ.
  final ViewMode liveView;
  final ViewMode movieView;

  /// Whether a film reopens where it was left off.
  final bool resumePlayback;

  /// How far one double-tap, or one arrow-key press, moves the playhead.
  final int skipSeconds;

  Duration get skip => Duration(seconds: skipSeconds);

  ViewMode viewFor(MediaKind kind) =>
      kind == MediaKind.live ? liveView : movieView;

  Settings copyWith({
    LiveContainer? liveContainer,
    String? userAgent,
    String? lastSourceId,
    String? lastPlayedId,
    bool? hardwareDecoding,
    int? bufferMegabytes,
    ViewMode? liveView,
    ViewMode? movieView,
    bool? resumePlayback,
    int? skipSeconds,
  }) {
    return Settings(
      liveContainer: liveContainer ?? this.liveContainer,
      userAgent: userAgent ?? this.userAgent,
      lastSourceId: lastSourceId ?? this.lastSourceId,
      lastPlayedId: lastPlayedId ?? this.lastPlayedId,
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
      bufferMegabytes: bufferMegabytes ?? this.bufferMegabytes,
      liveView: liveView ?? this.liveView,
      movieView: movieView ?? this.movieView,
      resumePlayback: resumePlayback ?? this.resumePlayback,
      skipSeconds: skipSeconds ?? this.skipSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'liveContainer': liveContainer.name,
    'userAgent': userAgent,
    'lastSourceId': lastSourceId,
    'lastPlayedId': lastPlayedId,
    'hardwareDecoding': hardwareDecoding,
    'bufferMegabytes': bufferMegabytes,
    'liveView': liveView.name,
    'movieView': movieView.name,
    'resumePlayback': resumePlayback,
    'skipSeconds': skipSeconds,
  };

  static Settings fromJson(Map<String, dynamic> json) {
    ViewMode view(String key, ViewMode fallback) => ViewMode.values.firstWhere(
      (v) => v.name == json[key],
      orElse: () => fallback,
    );
    return Settings(
      liveContainer: LiveContainer.values.firstWhere(
        (c) => c.name == json['liveContainer'],
        orElse: () => LiveContainer.ts,
      ),
      userAgent: json['userAgent'] as String? ?? defaultUserAgent,
      lastSourceId: json['lastSourceId'] as String?,
      lastPlayedId: json['lastPlayedId'] as String?,
      hardwareDecoding: json['hardwareDecoding'] as bool? ?? true,
      bufferMegabytes: json['bufferMegabytes'] as int? ?? 32,
      liveView: view('liveView', ViewMode.list),
      movieView: view('movieView', ViewMode.grid),
      resumePlayback: json['resumePlayback'] as bool? ?? true,
      skipSeconds: (json['skipSeconds'] as num?)?.toInt() ?? 10,
    );
  }
}

/// How far into a film the viewer got. Live channels have no meaningful
/// position, so only [MediaKind.movie] items are tracked.
class WatchProgress {
  const WatchProgress({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  /// 0..1, used to draw the bar across a poster.
  double get fraction => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  /// Below this there is nothing worth resuming; above it the film is
  /// effectively finished and should start over.
  static const minimum = Duration(seconds: 20);
  static const tailMargin = Duration(seconds: 45);

  bool get isResumable =>
      position >= minimum &&
      duration > Duration.zero &&
      position < duration - tailMargin;

  Map<String, dynamic> toJson() => {
    'position': position.inSeconds,
    'duration': duration.inSeconds,
  };

  static WatchProgress fromJson(Map<String, dynamic> json) => WatchProgress(
    position: Duration(seconds: (json['position'] as num?)?.toInt() ?? 0),
    duration: Duration(seconds: (json['duration'] as num?)?.toInt() ?? 0),
  );
}

/// Details reported by an Xtream panel after a successful login.
class XtreamAccount {
  const XtreamAccount({
    required this.username,
    required this.status,
    this.expiresAt,
    this.maxConnections,
    this.activeConnections,
    this.serverName,
  });

  final String username;
  final String status;
  final DateTime? expiresAt;
  final int? maxConnections;
  final int? activeConnections;
  final String? serverName;
}
