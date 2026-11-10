import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

/// Playback through Android's own ExoPlayer, drawn into a SurfaceView.
///
/// Why this exists beside libmpv: a car head unit stutters badly on a 1080p
/// H.264 channel here, with hardware decoding active, while a native Android
/// IPTV app plays the same channel faultlessly on the same screen. Opening one
/// of those apps up settles it — ExoPlayer, MediaCodec and a SurfaceView, and
/// no libmpv at all. mpv has to hand Flutter every frame as a texture for the
/// GPU to composite; a SurfaceView is handed straight to the display
/// controller. On a weak SoC that is the whole difference.
///
/// The surface sits under the ordinary Flutter controls, which do not change.
///
/// Tracks are reported as [media_kit] track objects so the track menus work
/// against either engine without knowing which is playing.
class ExoEngine {
  ExoEngine();

  static const _methods = MethodChannel('com.mytv.my_tv/exo');
  static const _events = EventChannel('com.mytv.my_tv/exo_events');

  /// The platform view type registered on the Android side.
  static const viewType = 'com.mytv.my_tv/exo_view';

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _track = StreamController<Track>.broadcast();

  StreamSubscription<Object?>? _subscription;

  Stream<bool> get playingStream => _playing.stream;
  Stream<bool> get bufferingStream => _buffering.stream;
  Stream<Duration> get positionStream => _position.stream;
  Stream<Duration> get durationStream => _duration.stream;
  Stream<String> get errorStream => _error.stream;
  Stream<Tracks> get tracksStream => _tracks.stream;
  Stream<Track> get trackStream => _track.stream;

  var _width = 0;
  var _height = 0;
  String? _decoder;
  String? _codec;
  var _dropped = 0;
  var _lastDuration = Duration.zero;

  int get width => _width;
  int get height => _height;

  /// The decoder's own name, as Android reports it — `c2.qti.avc.decoder`,
  /// `OMX.google.h264.decoder` and so on. A name starting with `c2.android.`
  /// or `OMX.google.` is a software decoder, which is worth knowing.
  String? get decoder => _decoder;
  String? get codec => _codec;
  int get droppedFrames => _dropped;

  Tracks tracks = const Tracks();
  Track activeTrack = const Track();

  /// Starts the native player. Call before [open].
  Future<void> create({
    required int bufferAheadSeconds,
    required int bufferAheadBytes,
  }) async {
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _error.add(e.toString()),
    );
    await _methods.invokeMethod<bool>('create', {
      'bufferAheadSeconds': bufferAheadSeconds,
      // ExoPlayer wants a byte target as an int; ours is already clamped.
      'bufferAheadBytes': bufferAheadBytes,
    });
  }

  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    Duration? startAt,
  }) async {
    await _methods.invokeMethod<bool>('open', {
      'url': url,
      'headers': headers,
      'startAtMs': (startAt ?? Duration.zero).inMilliseconds,
    });
  }

  Future<void> playOrPause() => _methods.invokeMethod<void>('playOrPause');

  Future<void> seek(Duration position) => _methods.invokeMethod<void>('seek', {
    'positionMs': position.inMilliseconds,
  });

  /// 0–100, matching the rest of the app and the volume slider.
  Future<void> setVolume(double percent) =>
      _methods.invokeMethod<void>('setVolume', {'volume': percent});

  Future<void> setAudioTrack(AudioTrack track) =>
      _methods.invokeMethod<void>('selectTrack', {
        'kind': 'audio',
        'id': track.id,
      });

  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _methods.invokeMethod<void>('selectTrack', {
        'kind': 'text',
        'id': track.id,
      });

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methods.invokeMethod<void>('dispose');
    } catch (_) {
      // Already gone; nothing to release.
    }
    await _playing.close();
    await _buffering.close();
    await _position.close();
    await _duration.close();
    await _error.close();
    await _tracks.close();
    await _track.close();
  }

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final event = raw['event'];
    switch (event) {
      case 'playing':
        _playing.add(raw['value'] == true);

      case 'buffering':
        _buffering.add(raw['value'] == true);

      case 'duration':
        _emitDuration(_ms(raw['valueMs']));

      case 'size':
        _width = (raw['width'] as num?)?.toInt() ?? 0;
        _height = (raw['height'] as num?)?.toInt() ?? 0;

      case 'error':
        _error.add((raw['message'] as String?) ?? 'Playback failed.');

      case 'tracks':
        _onTracks(raw);

      case 'tick':
        _position.add(_ms(raw['positionMs']));
        _emitDuration(_ms(raw['durationMs']));
        _decoder = raw['decoder'] as String?;
        _codec = raw['codec'] as String?;
        _dropped = (raw['dropped'] as num?)?.toInt() ?? 0;
    }
  }

  /// Live streams report no duration, and the UI treats a changed duration as
  /// a reason to re-check the resume position — so only real changes go out.
  void _emitDuration(Duration value) {
    if (value == _lastDuration) return;
    _lastDuration = value;
    _duration.add(value);
  }

  void _onTracks(Map<Object?, Object?> raw) {
    final audio = <AudioTrack>[AudioTrack.auto(), AudioTrack.no()];
    final subtitle = <SubtitleTrack>[SubtitleTrack.no()];

    for (final entry in (raw['audio'] as List?) ?? const []) {
      if (entry is! Map) continue;
      audio.add(
        AudioTrack(
          entry['id'] as String? ?? 'auto',
          entry['title'] as String?,
          entry['language'] as String?,
        ),
      );
    }
    for (final entry in (raw['text'] as List?) ?? const []) {
      if (entry is! Map) continue;
      subtitle.add(
        SubtitleTrack(
          entry['id'] as String? ?? 'no',
          entry['title'] as String?,
          entry['language'] as String?,
        ),
      );
    }

    tracks = Tracks(
      video: [VideoTrack.auto()],
      audio: audio,
      subtitle: subtitle,
    );

    final activeAudio = raw['activeAudio'] as String? ?? 'auto';
    final activeText = raw['activeText'] as String? ?? 'no';
    activeTrack = Track(
      video: VideoTrack.auto(),
      audio: audio.firstWhere(
        (t) => t.id == activeAudio,
        orElse: AudioTrack.auto,
      ),
      subtitle: subtitle.firstWhere(
        (t) => t.id == activeText,
        orElse: SubtitleTrack.no,
      ),
    );

    _tracks.add(tracks);
    _track.add(activeTrack);
  }

  static Duration _ms(Object? value) =>
      Duration(milliseconds: (value as num?)?.toInt() ?? 0);
}

/// The surface the ExoPlayer engine draws into.
///
/// Hybrid composition on purpose: [PlatformViewsService.initExpensiveAndroidView]
/// puts a real SurfaceView in the Android view hierarchy, which is the point of
/// the whole exercise. The cheaper texture-layer mode would hand the frames
/// back to Flutter and give up the saving.
///
/// Hit testing is transparent so the gesture detectors above keep working —
/// the tap to show controls, the double-tap skip, the swipe for the list.
class ExoVideo extends StatelessWidget {
  const ExoVideo({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: ExoEngine.viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const {},
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: ExoEngine.viewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }
}
