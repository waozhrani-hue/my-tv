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

  Future<Object?> _readJson(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } catch (_) {
      // A truncated or hand-edited file should not block startup.
      return null;
    }
  }

  Future<void> _writeJson(String name, Object value) async {
    // Write to a sibling first so a crash mid-write cannot leave a half file.
    final target = _file(name);
    final temp = _file('$name.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
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

  Future<Set<String>> readFavorites() async {
    final data = await _readJson('favorites.json');
    if (data is! List) return {};
    return data.whereType<String>().toSet();
  }

  Future<void> writeFavorites(Set<String> ids) =>
      _writeJson('favorites.json', ids.toList());

  Future<List<String>> readRecents() async {
    final data = await _readJson('recents.json');
    if (data is! List) return [];
    return data.whereType<String>().toList();
  }

  Future<void> writeRecents(List<String> ids) =>
      _writeJson('recents.json', ids);

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
