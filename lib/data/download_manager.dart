import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'models.dart';

/// Keeps films on the device so they play with no network.
///
/// One transfer runs at a time, deliberately: IPTV accounts are usually
/// limited to a couple of simultaneous connections, and saturating them would
/// break live playback while a film downloads.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this._store, {http.Client? client})
    : _client = client ?? http.Client();

  final LocalStore _store;
  final http.Client _client;

  /// Keyed by item id, in the order they were added.
  final Map<String, DownloadRecord> _records = {};

  Directory? _directory;
  String? _activeId;
  var _cancelRequested = false;
  var _loaded = false;

  /// Set while something is playing.
  ///
  /// IPTV accounts are often capped at a single simultaneous connection, and
  /// a download holds it — so with one running, nothing plays at all and the
  /// server answers every stream request with a refusal. Downloads stand
  /// aside for playback and pick up where they stopped afterwards.
  var _suspended = false;
  String? _userAgent;

  bool get isSuspended => _suspended;

  List<DownloadRecord> get records => _records.values.toList();
  bool get isEmpty => _records.isEmpty;
  bool get hasActive => _records.values.any((r) => r.isActive);

  DownloadRecord? recordFor(String id) => _records[id];

  /// The local file for a finished download, or null if it is not on disk.
  String? localPathFor(String id) {
    final record = _records[id];
    if (record == null || !record.isComplete) return null;
    return File(record.path).existsSync() ? record.path : null;
  }

  int get bytesOnDisk => _records.values
      .where((r) => r.isComplete)
      .fold(0, (sum, r) => sum + r.totalBytes);

  /// Reads the saved list and drops anything whose file has gone.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final saved = await _store.readDownloads();
    for (final record in saved) {
      if (record.isComplete && !File(record.path).existsSync()) continue;
      _records[record.item.id] = record;
    }
    notifyListeners();
    // Anything left queued by a previous run carries on now.
    unawaited(_pump());
  }

  Future<Directory> _dir() async {
    final existing = _directory;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}downloads',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return _directory = dir;
  }

  // --- Queue ---------------------------------------------------------------

  /// Adds a film to the queue. Live channels are refused: there is no end to
  /// download, and the file would grow until the disk filled.
  Future<void> enqueue(MediaItem item, {required String userAgent}) async {
    if (item.kind != MediaKind.movie) return;
    final existing = _records[item.id];
    if (existing != null && (existing.isActive || existing.isComplete)) return;

    final dir = await _dir();
    final path =
        '${dir.path}${Platform.pathSeparator}${_fileName(item)}';

    _records[item.id] = DownloadRecord(item: item, path: path);
    notifyListeners();
    await _save();
    unawaited(_pump(userAgent: userAgent));
  }

  /// Stops the transfer and forgets it, deleting whatever arrived.
  Future<void> remove(String id) async {
    final record = _records.remove(id);
    if (record == null) return;
    if (_activeId == id) _cancelRequested = true;
    notifyListeners();

    for (final file in [File(record.path), File('${record.path}.part')]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // A file held open by the player is removed on the next sweep.
      }
    }
    await _save();
  }

  Future<void> removeCompleted() async {
    for (final record in records.where((r) => r.isComplete)) {
      await remove(record.item.id);
    }
  }

  Future<void> retry(String id, {required String userAgent}) async {
    final record = _records[id];
    if (record == null || record.isComplete || record.isActive) return;
    _records[id] = record.copyWith(
      state: DownloadState.queued,
      clearError: true,
    );
    notifyListeners();
    await _save();
    unawaited(_pump(userAgent: userAgent));
  }

  // --- Playback takes priority ---------------------------------------------

  /// Stops the running transfer so playback can have the connection. What has
  /// arrived is kept, and resumes from that byte afterwards.
  void suspendForPlayback() {
    if (_suspended) return;
    _suspended = true;
    if (_activeId != null) {
      _cancelRequested = true;
      // Back to queued, not failed: this is a pause, not an error.
      final record = _records[_activeId];
      if (record != null) {
        _records[_activeId!] = record.copyWith(
          state: DownloadState.queued,
          clearError: true,
        );
      }
    }
    notifyListeners();
  }

  /// Picks downloading back up once nothing is playing.
  void resumeAfterPlayback() {
    if (!_suspended) return;
    _suspended = false;
    notifyListeners();
    unawaited(_pump(userAgent: _userAgent));
  }

  // --- Transfer ------------------------------------------------------------

  Future<void> _pump({String? userAgent}) async {
    if (userAgent != null) _userAgent = userAgent;
    if (_activeId != null || _suspended) return;

    final next = _records.values
        .where((r) => r.state == DownloadState.queued)
        .firstOrNull;
    if (next == null) return;

    _activeId = next.item.id;
    _cancelRequested = false;
    try {
      await _run(next, userAgent ?? Settings.defaultUserAgent);
    } finally {
      _activeId = null;
    }
    // Carry on with whatever is still queued.
    unawaited(_pump(userAgent: userAgent));
  }

  Future<void> _run(DownloadRecord record, String userAgent) async {
    final id = record.item.id;
    void update(DownloadRecord next) {
      if (!_records.containsKey(id)) return;
      _records[id] = next;
      notifyListeners();
    }

    update(record.copyWith(state: DownloadState.running, clearError: true));

    final partial = File('${record.path}.part');
    var alreadyHave = 0;
    if (await partial.exists()) alreadyHave = await partial.length();

    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(record.item.url))
        ..headers['User-Agent'] = userAgent
        ..headers.addAll(record.item.httpHeaders);
      // Pick up where a previous attempt stopped rather than starting over.
      if (alreadyHave > 0) {
        request.headers['Range'] = 'bytes=$alreadyHave-';
      }

      final response = await _client.send(request).timeout(
        const Duration(seconds: 45),
      );

      if (response.statusCode == 200 && alreadyHave > 0) {
        // The server ignored the range and is sending the whole file again.
        alreadyHave = 0;
        await partial.writeAsBytes(const [], flush: true);
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('The server returned HTTP ${response.statusCode}.');
      }

      final total = (response.contentLength ?? 0) + alreadyHave;
      var received = alreadyHave;
      update(
        _records[id]!.copyWith(receivedBytes: received, totalBytes: total),
      );

      final out = partial.openWrite(mode: FileMode.append);
      sink = out;
      var lastPercent = -1;

      await for (final chunk in response.stream) {
        // Cancelled, removed, or standing aside for playback. In every case
        // the .part file stays, so the next attempt resumes from here.
        if (_cancelRequested || _suspended || !_records.containsKey(id)) {
          await out.flush();
          await out.close();
          sink = null;
          return;
        }
        out.add(chunk);
        received += chunk.length;

        // Rebuild on whole percents only; a 2 GB film arrives in tens of
        // thousands of chunks.
        final percent = total > 0 ? (received * 100) ~/ total : -1;
        if (percent != lastPercent) {
          lastPercent = percent;
          update(_records[id]!.copyWith(receivedBytes: received));
        }
      }

      await out.flush();
      await out.close();
      sink = null;

      if (total > 0 && received < total) {
        throw const HttpException('The download ended early.');
      }

      final target = File(record.path);
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);

      update(
        _records[id]!.copyWith(
          state: DownloadState.completed,
          receivedBytes: received,
          totalBytes: received,
          completedAt: DateTime.now(),
          clearError: true,
        ),
      );
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {
        // Already closed.
      }
      if (_records.containsKey(id)) {
        update(
          _records[id]!.copyWith(
            state: DownloadState.failed,
            error: _message(e),
          ),
        );
      }
    } finally {
      await _save();
    }
  }

  Future<void> _save() => _store.writeDownloads(records);

  static String _message(Object error) => switch (error) {
    TimeoutException() => 'The server stopped responding.',
    HttpException(message: final m) => m,
    SocketException() => 'No connection to the server.',
    _ => error.toString(),
  };

  /// A safe file name that still hints at what the file is.
  static String _fileName(MediaItem item) {
    final extension = _extension(item.url);
    final safeId = item.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$safeId$extension';
  }

  static String _extension(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '.mp4';
    final extension = path.substring(dot).toLowerCase();
    // Guard against a query string or something odd ending up in the name.
    return RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(extension)
        ? extension
        : '.mp4';
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _client.close();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
