import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// On-disk state: configured sources, favourites, watch history, settings and
/// the parsed-playlist cache. Plain JSON files — the data is small and a
/// database would buy nothing here.
class LocalStore {
  LocalStore._(this._dir);

  final Directory _dir;

  static Future<LocalStore> open() async =>
      openIn(await getApplicationSupportDirectory());

  /// Opens the store under an explicit directory.
  ///
  /// Tests use this: the host platform has no path_provider implementation,
  /// so [open] would hang waiting on a channel nothing answers.
  static Future<LocalStore> openIn(Directory base) async {
    final dir = Directory('${base.path}${Platform.pathSeparator}data');
    if (!await dir.exists()) await dir.create(recursive: true);
    return LocalStore._(dir);
  }

  File _file(String name) =>
      File('${_dir.path}${Platform.pathSeparator}$name');

  /// Reads a file, falling back to the previous copy.
  ///
  /// Returning null here means "no data", and the caller turns that into an
  /// empty set which the next write then makes permanent — so a file that is
  /// merely unreadable for a moment must not reach that path. The `.bak`
  /// companion makes losing anything take two failures instead of one.
  Future<Object?> _readJson(String name) async {
    for (final candidate in [_file(name), _file('$name.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        final text = await candidate.readAsString();
        if (text.trim().isEmpty) continue;
        return jsonDecode(text);
      } catch (_) {
        // Truncated or hand-edited: try the backup rather than giving up.
        continue;
      }
    }
    return null;
  }

  Future<void> _writeJson(String name, Object value) async {
    final target = _file(name);
    final temp = _file('$name.tmp');
    final backup = _file('$name.bak');

    // Write beside the target first, so a crash mid-write cannot truncate it.
    await temp.writeAsString(jsonEncode(value), flush: true);

    // Keep the last known-good copy before replacing it.
    if (await target.exists()) {
      try {
        await target.copy(backup.path);
      } catch (_) {
        // A missing backup is survivable; a failed write is not.
      }
    }

    try {
      // On POSIX this replaces the target atomically, so there is never a
      // moment with no file - which is exactly when installing an update
      // kills the process.
      await temp.rename(target.path);
    } on FileSystemException {
      // Windows refuses to rename onto an existing file, so there it has to
      // be a delete first. The backup above covers that window.
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    }
  }

  // --- Sources -------------------------------------------------------------

  Future<List<PlaylistSource>> readSources() async {
    final data = await _readJson('sources.json');
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .map(PlaylistSource.fromJson)
        .toList();
  }

  Future<void> writeSources(List<PlaylistSource> sources) =>
      _writeJson('sources.json', sources.map((s) => s.toJson()).toList());

  // --- Favourites and history ---------------------------------------------

  /// Favourites and history store the whole item, not just its id.
  ///
  /// Ids alone meant the lists could only be shown by matching them against a
  /// loaded catalog, so they looked empty whenever the catalog was still
  /// loading, had failed, or had been cleared — which reads exactly like the
  /// data having been lost.
  Future<List<MediaItem>> readFavorites() => _readItems('favorites.json');

  Future<void> writeFavorites(List<MediaItem> items) =>
      _writeItems('favorites.json', items);

  Future<List<MediaItem>> readRecents() => _readItems('recents.json');

  Future<void> writeRecents(List<MediaItem> items) =>
      _writeItems('recents.json', items);

  Future<List<MediaItem>> _readItems(String name) async {
    final data = await _readJson(name);
    if (data is! List) return [];
    final out = <MediaItem>[];
    for (final entry in data) {
      if (entry is Map) {
        out.add(MediaItem.fromJson(entry.cast<String, dynamic>()));
      } else if (entry is String) {
        // Written before 1.4, when only ids were stored. Keep the entry so it
        // is not dropped; it is filled in the first time the catalog loads.
        out.add(MediaItem.placeholder(entry));
      }
    }
    return out;
  }

  Future<void> _writeItems(String name, List<MediaItem> items) =>
      _writeJson(name, items.map((e) => e.toJson()).toList());

  // --- Watch progress ------------------------------------------------------

  Future<Map<String, WatchProgress>> readProgress() async {
    final data = await _readJson('progress.json');
    if (data is! Map) return {};
    final out = <String, WatchProgress>{};
    data.forEach((key, value) {
      if (key is String && value is Map) {
        out[key] = WatchProgress.fromJson(value.cast<String, dynamic>());
      }
    });
    return out;
  }

  Future<void> writeProgress(Map<String, WatchProgress> progress) => _writeJson(
    'progress.json',
    {for (final e in progress.entries) e.key: e.value.toJson()},
  );

  // --- Settings ------------------------------------------------------------

  Future<Settings> readSettings() async {
    final data = await _readJson('settings.json');
    if (data is! Map) return const Settings();
    return Settings.fromJson(data.cast<String, dynamic>());
  }

  Future<void> writeSettings(Settings settings) =>
      _writeJson('settings.json', settings.toJson());

  // --- Catalog cache -------------------------------------------------------

  Future<Catalog?> readCatalog(String sourceId) async {
    final data = await _readJson('catalog_$sourceId.json');
    if (data is! Map) return null;
    return Catalog.fromJson(data.cast<String, dynamic>());
  }

  Future<void> writeCatalog(String sourceId, Catalog catalog) =>
      _writeJson('catalog_$sourceId.json', catalog.toJson());

  Future<void> deleteCatalog(String sourceId) async {
    final file = _file('catalog_$sourceId.json');
    if (await file.exists()) await file.delete();
  }
}
