import 'dart:async';

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
  Set<String> _favorites = const {};
  List<String> _recents = const [];
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

  bool isFavorite(String id) => _favorites.contains(id);

  MediaItem? itemById(String id) => _index[id];

  /// Reads everything off disk and loads the last used playlist.
  Future<void> bootstrap() async {
    _sources = await _store.readSources();
    _favorites = await _store.readFavorites();
    _recents = await _store.readRecents();
    _progress = await _store.readProgress();
    _settings = await _store.readSettings();
    _booted = true;

    // Not awaited: an update check must never hold up the first screen.
    unawaited(checkForUpdate());

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

  Future<void> toggleFavorite(String id) async {
    final next = {..._favorites};
    if (!next.remove(id)) next.add(id);
    _favorites = next;
    notifyListeners();
    await _store.writeFavorites(next);
  }

  Future<void> noteWatched(MediaItem item) async {
    _recents = [item.id, ..._recents.where((id) => id != item.id)]
        .take(_recentLimit)
        .toList();
    await _store.writeRecents(_recents);
    await _saveSettings(_settings.copyWith(lastPlayedId: item.id));
  }

  /// Favourites that exist in the current catalog, in catalog order.
  List<MediaItem> get favoriteItems => [
    for (final item in [..._catalog.live, ..._catalog.movies])
      if (_favorites.contains(item.id)) item,
  ];

  /// History, most recent first, skipping anything no longer in the catalog.
  List<MediaItem> get recentItems => [
    for (final id in _recents) ?_index[id],
  ];

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
    try {
      _update = await _updates.check();
    } on UpdateException {
      _update = null;
    } catch (_) {
      _update = null;
    }
    _updateChecked = true;
    notifyListeners();
    return _update;
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
