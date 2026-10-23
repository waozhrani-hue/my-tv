import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/local_store.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/update_service.dart';

enum LoadStatus { idle, loading, ready, error }

/// The single source of truth for the UI. Owns the configured playlists, the
/// catalog of whichever one is selected, and the user's favourites, history
/// and settings.
class AppState extends ChangeNotifier {
  AppState(this._store, this._repository, {UpdateService? updates})
    : _updates = updates ?? UpdateService();

  final LocalStore _store;
  final Repository _repository;
  final UpdateService _updates;

  /// Most recent items kept in history.
  static const _recentLimit = 40;

  List<PlaylistSource> _sources = const [];
  PlaylistSource? _current;
  Catalog _catalog = const Catalog();
  LoadStatus _status = LoadStatus.idle;
  String? _error;
  /// id -> item, so a favourite can be shown and played without the catalog.
  Map<String, MediaItem> _favorites = const {};

  /// Most recent first.
  List<MediaItem> _recents = const [];
  Map<String, WatchProgress> _progress = const {};
  Settings _settings = const Settings();
  var _booted = false;

  /// id -> item, rebuilt whenever a catalog lands.
  Map<String, MediaItem> _index = const {};

  List<PlaylistSource> get sources => _sources;
  PlaylistSource? get current => _current;
  Catalog get catalog => _catalog;
  LoadStatus get status => _status;
  String? get error => _error;
  Settings get settings => _settings;
  bool get booted => _booted;
  bool get hasSources => _sources.isNotEmpty;

  bool isFavorite(String id) => _favorites.containsKey(id);

  MediaItem? itemById(String id) => _index[id];

  /// Reads everything off disk and loads the last used playlist.
  Future<void> bootstrap() async {
    _sources = await _store.readSources();
    _favorites = {for (final item in await _store.readFavorites()) item.id: item};
    _recents = await _store.readRecents();
    _progress = await _store.readProgress();
    _settings = await _store.readSettings();
    _booted = true;

    // Neither is awaited: an update check must never hold up the first screen.
    unawaited(checkForUpdate());
    unawaited(syncBackgroundDownload());

    final wanted = _settings.lastSourceId;
    final start = _sources.firstWhereOrNull((s) => s.id == wanted) ??
        (_sources.isEmpty ? null : _sources.first);
    if (start == null) {
      notifyListeners();
      return;
    }
    _current = start;
    notifyListeners();
    await _load(start);
  }

  Future<void> addSource(PlaylistSource source) async {
    _sources = [..._sources, source];
    await _store.writeSources(_sources);
    await selectSource(source.id);
  }

  Future<void> updateSource(PlaylistSource source) async {
    _sources = [
      for (final s in _sources) if (s.id == source.id) source else s,
    ];
    await _store.writeSources(_sources);
    await _store.deleteCatalog(source.id);
    if (_current?.id == source.id) {
      _current = source;
      await _load(source, forceRefresh: true);
    } else {
      notifyListeners();
    }
  }

  Future<void> removeSource(String id) async {
    _sources = _sources.where((s) => s.id != id).toList();
    await _store.writeSources(_sources);
    await _store.deleteCatalog(id);

    if (_current?.id == id) {
      _current = _sources.isEmpty ? null : _sources.first;
      _catalog = const Catalog();
      _index = const {};
      _status = LoadStatus.idle;
      _error = null;
      final next = _current;
      notifyListeners();
      if (next != null) await _load(next);
    } else {
      notifyListeners();
    }
  }

  Future<void> selectSource(String id) async {
    final source = _sources.firstWhereOrNull((s) => s.id == id);
    if (source == null || _current?.id == id && _status == LoadStatus.ready) {
      return;
    }
    _current = source;
    await _saveSettings(_settings.copyWith(lastSourceId: id));
    await _load(source);
  }

  Future<void> refresh() async {
    final source = _current;
    if (source == null) return;
    await _load(source, forceRefresh: true);
  }

  Future<void> _load(PlaylistSource source, {bool forceRefresh = false}) async {
    _status = LoadStatus.loading;
    _error = null;
    notifyListeners();

    try {
      final catalog = await _repository.load(
        source,
        _settings,
        forceRefresh: forceRefresh,
      );
      // A slower load for a playlist the user has since navigated away from
      // must not overwrite the current one.
      if (_current?.id != source.id) return;
      _catalog = catalog;
      _index = {
        for (final item in [...catalog.live, ...catalog.movies]) item.id: item,
      };
      _status = LoadStatus.ready;
      _error = null;
      unawaited(_refreshSavedItems());
    } catch (e) {
      if (_current?.id != source.id) return;
      _catalog = const Catalog();
      _index = const {};
      _status = LoadStatus.error;
      _error = e is PlaylistException ? e.message : e.toString();
    }
    notifyListeners();
  }

  // --- Favourites and history ---------------------------------------------

  Future<void> toggleFavorite(MediaItem item) async {
    final next = {..._favorites};
    if (next.remove(item.id) == null) next[item.id] = item;
    _favorites = next;
    notifyListeners();
    await _store.writeFavorites(next.values.toList());
  }

  Future<void> noteWatched(MediaItem item) async {
    _recents = [
      item,
      ..._recents.where((e) => e.id != item.id),
    ].take(_recentLimit).toList();
    await _store.writeRecents(_recents);
    await _saveSettings(_settings.copyWith(lastPlayedId: item.id));
  }

  /// Favourites, preferring the catalog's copy when it is loaded so the URL
  /// and artwork are current, and otherwise the saved one.
  List<MediaItem> get favoriteItems => [
    for (final saved in _favorites.values) ?_resolve(saved),
  ];

  /// History, most recent first, on the same terms.
  List<MediaItem> get recentItems => [
    for (final saved in _recents) ?_resolve(saved),
  ];

  /// The catalog's copy when it is loaded, else the saved one — unless that
  /// is a pre-1.4 placeholder, which carries no URL and cannot be played.
  MediaItem? _resolve(MediaItem saved) =>
      _index[saved.id] ?? (saved.isPlayable ? saved : null);

  /// Replaces saved favourites and history with the catalog's own copies, so
  /// a renamed channel or a changed stream URL is picked up, and entries saved
  /// before whole items were stored get filled in.
  Future<void> _refreshSavedItems() async {
    if (_index.isEmpty) return;

    var favoritesChanged = false;
    final favorites = <String, MediaItem>{};
    for (final entry in _favorites.entries) {
      final fresh = _index[entry.key];
      favorites[entry.key] = fresh ?? entry.value;
      if (fresh != null && fresh.url != entry.value.url) favoritesChanged = true;
    }

    var recentsChanged = false;
    final recents = <MediaItem>[];
    for (final saved in _recents) {
      final fresh = _index[saved.id];
      recents.add(fresh ?? saved);
      if (fresh != null && fresh.url != saved.url) recentsChanged = true;
    }

    if (favoritesChanged) {
      _favorites = favorites;
      await _store.writeFavorites(favorites.values.toList());
    }
    if (recentsChanged) {
      _recents = recents;
      await _store.writeRecents(recents);
    }
    if (favoritesChanged || recentsChanged) notifyListeners();
  }

  MediaItem? get lastPlayed {
    final id = _settings.lastPlayedId;
    return id == null ? null : _index[id];
  }

  // --- Watch progress ------------------------------------------------------

  /// Where this film was left off, or null if there is nothing to resume.
  WatchProgress? progressFor(String id) {
    final saved = _progress[id];
    return (saved != null && saved.isResumable) ? saved : null;
  }

  /// Records how far into [item] the viewer got. A film that has run to its
  /// last minute is dropped rather than stored, so it starts over next time.
  Future<void> saveProgress(
    MediaItem item,
    Duration position,
    Duration duration,
  ) async {
    if (item.kind != MediaKind.movie) return;

    final entry = WatchProgress(position: position, duration: duration);
    final next = {..._progress};
    if (entry.isResumable) {
      final existing = next[item.id];
      // Avoid a disk write for a position that has barely moved.
      if (existing != null &&
          (existing.position - position).abs() < const Duration(seconds: 3)) {
        return;
      }
      next[item.id] = entry;
    } else if (!next.containsKey(item.id)) {
      return;
    } else {
      next.remove(item.id);
    }

    _progress = next;
    notifyListeners();
    await _store.writeProgress(next);
  }

  Future<void> clearProgress(String id) async {
    if (!_progress.containsKey(id)) return;
    final next = {..._progress}..remove(id);
    _progress = next;
    notifyListeners();
    await _store.writeProgress(next);
  }

  // --- Settings ------------------------------------------------------------

  Future<void> updateSettings(Settings next) async {
    final containerChanged = next.liveContainer != _settings.liveContainer;
    final agentChanged = next.userAgent != _settings.userAgent;
    await _saveSettings(next);

    // Xtream stream URLs embed the container, and the cached catalog holds
    // those URLs, so both of these invalidate the cache.
    if (containerChanged || agentChanged) {
      for (final source in _sources) {
        await _store.deleteCatalog(source.id);
      }
      await refresh();
    }
  }

  Future<void> _saveSettings(Settings next) async {
    _settings = next;
    notifyListeners();
    await _store.writeSettings(next);
  }

  // --- Updates -------------------------------------------------------------

  AppRelease? _update;
  var _updateChecked = false;

  UpdateService get updates => _updates;

  /// The newest published release when it is ahead of this build.
  AppRelease? get availableUpdate => _update;
  bool get updateChecked => _updateChecked;

  /// Asks GitHub whether there is a newer build. Startup calls this without
  /// awaiting it, so a slow or absent network never delays the UI.
  Future<AppRelease?> checkForUpdate() async {
    final previous = _update?.version;
    try {
      _update = await _updates.check();
    } on UpdateException {
      _update = null;
    } catch (_) {
      _update = null;
    }
    // A file downloaded for an older release must not be offered for a new
    // one; a download in flight is left alone.
    if (_update?.version != previous && !_downloading) {
      _downloadedUpdate = null;
      _downloadProgress = 0;
      _downloadError = null;
    }
    _updateChecked = true;
    notifyListeners();
    return _update;
  }

  // --- Update download ------------------------------------------------------
  //
  // Held here rather than in the settings screen so that leaving that screen
  // does not abandon a download part-way: the transfer keeps going and the
  // progress is still there when the user comes back, or shows on the header
  // badge from anywhere in the app.

  var _downloading = false;
  var _downloadProgress = 0.0;
  File? _downloadedUpdate;
  String? _downloadError;

  bool get isDownloadingUpdate => _downloading;
  double get downloadProgress => _downloadProgress;
  File? get downloadedUpdate => _downloadedUpdate;
  String? get downloadError => _downloadError;

  Timer? _downloadPoll;

  /// Picks up a download that the foreground service may still be running, or
  /// has finished, from a previous run of the app.
  Future<void> syncBackgroundDownload() async {
    if (!Platform.isAndroid) return;
    final status = await _updates.backgroundStatus();
    switch (status.state) {
      case DownloadState.running:
        _downloading = true;
        _downloadProgress = status.progress;
        _watchBackgroundDownload();
      case DownloadState.done:
        _downloading = false;
        _downloadProgress = 1;
        _downloadedUpdate = status.file;
      case DownloadState.failed:
        _downloading = false;
        _downloadError = status.error;
      case DownloadState.idle:
        return;
    }
    notifyListeners();
  }

  /// Mirrors the service's progress into the UI while the app is open. The
  /// download itself does not depend on this timer.
  void _watchBackgroundDownload() {
    _downloadPoll?.cancel();
    _downloadPoll = Timer.periodic(const Duration(milliseconds: 600), (
      timer,
    ) async {
      final status = await _updates.backgroundStatus();
      switch (status.state) {
        case DownloadState.running:
          if ((status.progress - _downloadProgress).abs() < 0.005) return;
          _downloadProgress = status.progress;
        case DownloadState.done:
          timer.cancel();
          _downloading = false;
          _downloadProgress = 1;
          _downloadedUpdate = status.file;
        case DownloadState.failed:
          timer.cancel();
          _downloading = false;
          _downloadError = status.error ?? 'The download failed.';
        case DownloadState.idle:
          timer.cancel();
          _downloading = false;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _downloadPoll?.cancel();
    super.dispose();
  }

  /// Fetches the pending release. Safe to call again while one is running:
  /// the second call returns the same work rather than starting a parallel
  /// download of the same file.
  ///
  /// On Android this starts a foreground service and returns immediately —
  /// the transfer continues with the app closed, and the finished file
  /// arrives through [syncBackgroundDownload] or the poll above.
  Future<File?> downloadUpdate() async {
    final release = _update;
    if (release == null) return null;
    if (_downloading) return null;
    if (_downloadedUpdate != null) return _downloadedUpdate;

    _downloading = true;
    _downloadProgress = 0;
    _downloadError = null;
    notifyListeners();

    if (Platform.isAndroid) {
      try {
        await _updates.clearBackgroundStatus();
        await _updates.startBackgroundDownload(release);
        _watchBackgroundDownload();
      } catch (e) {
        _downloading = false;
        _downloadError = e is UpdateException
            ? e.message
            : 'Could not start the download — $e';
        notifyListeners();
      }
      return null;
    }

    try {
      // Notify once per whole percent; a 90 MB file arrives in thousands of
      // chunks and rebuilding the UI for each would be pointless work.
      var lastPercent = -1;
      final file = await _updates.download(
        release,
        onProgress: (p) {
          final percent = (p * 100).round();
          if (percent == lastPercent) return;
          lastPercent = percent;
          _downloadProgress = p;
          notifyListeners();
        },
      );
      _downloadedUpdate = file;
      return file;
    } on UpdateException catch (e) {
      _downloadError = e.message;
      return null;
    } catch (e) {
      _downloadError = 'The download failed — $e';
      return null;
    } finally {
      _downloading = false;
      notifyListeners();
    }
  }

  void clearDownloadError() {
    if (_downloadError == null) return;
    _downloadError = null;
    notifyListeners();
  }

  /// Checks Xtream credentials from the add/edit form, before anything is
  /// written to disk.
  Future<XtreamAccount> verifyXtream({
    required String host,
    required String username,
    required String password,
    String? userAgent,
  }) {
    return _repository.verifyXtream(
      host,
      username,
      password,
      userAgent ?? _settings.userAgent,
    );
  }

  // --- Queries -------------------------------------------------------------

  /// Filters the catalog for the browse screen.
  List<MediaItem> query({
    required MediaKind kind,
    String? group,
    String search = '',
  }) {
    final needle = search.trim().toLowerCase();
    final source = kind == MediaKind.live ? _catalog.live : _catalog.movies;
    return [
      for (final item in source)
        if ((group == null || (item.group ?? '').trim() == group) &&
            (needle.isEmpty || item.name.toLowerCase().contains(needle)))
          item,
    ];
  }

  /// Channels adjacent to [item] within its own group, for next/previous
  /// zapping in the player.
  List<MediaItem> zapListFor(MediaItem item) {
    final pool = item.kind == MediaKind.live ? _catalog.live : _catalog.movies;
    final group = (item.group ?? '').trim();
    if (group.isEmpty) return pool;
    final inGroup = pool.where((e) => (e.group ?? '').trim() == group).toList();
    return inGroup.length > 1 ? inGroup : pool;
  }
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
