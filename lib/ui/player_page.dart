import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Full-screen playback with its own controls. One [Player] is kept alive for
/// the whole visit, so zapping between channels reuses the decoder.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.item});

  final MediaItem item;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _hideDelay = Duration(milliseconds: 3500);

  /// How long the skip indicator stays up. Another double-tap inside this
  /// window adds to the same burst instead of starting a new one, which is
  /// what makes repeated taps feel like one continuous scrub.
  static const _burstWindow = Duration(milliseconds: 900);

  late final Player _player;
  late final VideoController _controller;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _focus = FocusNode();

  late final AppState _app;
  late MediaItem _item;
  Timer? _hideTimer;
  Timer? _progressTimer;

  /// Set when a film has a saved position; applied once the duration is known,
  /// because seeking before that is ignored.
  Duration? _pendingResume;

  // Double-tap skip, YouTube style: the running total for the current burst,
  // which side it is on, and whether the indicator is showing.
  Timer? _burstTimer;
  var _burstSeconds = 0;
  var _burstForward = true;
  var _burstVisible = false;
  Offset? _lastTapPosition;

  // The channel list that slides over the video. It keeps its own hide timer:
  // a longer one than the controls, because reading a list takes longer than
  // glancing at a progress bar.
  static const _listHideDelay = Duration(seconds: 9);
  Timer? _listTimer;
  var _listVisible = false;
  final _listScroll = ScrollController();

  var _controlsVisible = true;
  var _playing = false;
  var _buffering = true;
  var _fullscreen = false;
  var _muted = false;
  double _volume = 100;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late Tracks _tracks;
  late Track _activeTrack;
  String? _error;

  bool get _isLive => _item.kind == MediaKind.live;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _item = widget.item;

    final settings = _app.settings;
    _player = Player(
      configuration: PlayerConfiguration(
        title: 'My TV',
        // Live streams stall on small buffers; this is the main knob that
        // decides how well a flaky provider plays.
        bufferSize: settings.bufferMegabytes * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: settings.hardwareDecoding,
      ),
    );
    _tracks = _player.state.tracks;
    _activeTrack = _player.state.track;
    _volume = _player.state.volume;

    // A provider that allows one connection at a time gives it to whichever
    // asks first, so a running download would leave nothing to play with.
    _app.downloads.suspendForPlayback();

    _listen();
    _applyNativeOptions(settings);
    _open(_item);
    WakelockPlus.enable();
    _restartHideTimer();

    // Films remember where they were left off; the timer keeps that current
    // so a crash or a force-quit still leaves a usable position.
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _recordProgress(),
    );
  }

  void _recordProgress() {
    if (_item.kind != MediaKind.movie) return;
    if (!_playing || _duration <= Duration.zero) return;
    _app.saveProgress(_item, _position, _duration);
  }

  void _listen() {
    _subscriptions.addAll([
      _player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }),
      _player.stream.position.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
      _player.stream.duration.listen((v) {
        if (!mounted) return;
        setState(() => _duration = v);
        _applyPendingResume(v);
      }),
      _player.stream.volume.listen((v) {
        if (mounted) setState(() => _volume = v);
      }),
      _player.stream.tracks.listen((v) {
        if (mounted) setState(() => _tracks = v);
      }),
      _player.stream.track.listen((v) {
        if (mounted) setState(() => _activeTrack = v);
      }),
      _player.stream.error.listen((message) {
        if (mounted) setState(() => _error = message);
      }),
    ]);
  }

  /// mpv options that are not exposed through [PlayerConfiguration] but matter
  /// for IPTV: a sane network timeout and the provider's expected User-Agent.
  Future<void> _applyNativeOptions(Settings settings) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('network-timeout', '20');
      await platform.setProperty('user-agent', settings.userAgent);
      // Keep playing from the live edge after a stall rather than drifting.
      await platform.setProperty('cache-pause-initial', 'yes');
      await platform.setProperty('cache-pause-wait', '2');
    } catch (_) {
      // Non-fatal: these are tuning hints, not requirements.
    }
  }

  Future<void> _open(MediaItem item) async {
    setState(() {
      _error = null;
      _buffering = true;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    _pendingResume = item.kind == MediaKind.movie && _app.settings.resumePlayback
        ? _app.progressFor(item.id)?.position
        : null;

    // A saved copy plays from the device, so a film opened on a flight needs
    // no network at all.
    final playable = _app.playableFor(item);
    final headers = <String, String>{
      'User-Agent': _app.settings.userAgent,
      ...playable.httpHeaders,
    };

    try {
      await _player.open(Media(playable.url, httpHeaders: headers));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    await _app.noteWatched(item);
  }

  /// mpv only reports a duration once it has read the container header, and a
  /// seek issued before that is dropped — so the resume waits for it.
  void _applyPendingResume(Duration duration) {
    final target = _pendingResume;
    if (target == null || duration <= Duration.zero) return;
    _pendingResume = null;
    if (target >= duration - WatchProgress.tailMargin) return;
    _player.seek(target);
    _showResumeNotice(target);
  }

  void _showResumeNotice(Duration at) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Resumed from ${formatClock(at)}'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Start over',
          onPressed: () {
            _player.seek(Duration.zero);
            _app.clearProgress(_item.id);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _burstTimer?.cancel();
    _listTimer?.cancel();
    _listScroll.dispose();
    // Capture the final position before the player is torn down.
    if (_item.kind == MediaKind.movie && _duration > Duration.zero) {
      _app.saveProgress(_item, _position, _duration);
    }
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _focus.dispose();
    _player.dispose();
    _app.downloads.resumeAfterPlayback();
    WakelockPlus.disable();
    // Leaving the player must not leave the shell in fullscreen.
    if (_fullscreen) _exitFullscreenChrome();
    super.dispose();
  }

  // --- Controls visibility --------------------------------------------------

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _poke() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _toggleControls() {
    // With the list open, a tap on the video dismisses it rather than
    // toggling the controls underneath — the nearer thing wins.
    if (_listVisible) {
      _hideList();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartHideTimer();
  }

  // --- Channel list ---------------------------------------------------------

  /// Everything that can be switched to from here: the current category, or
  /// the whole section when the category holds only this one item.
  List<MediaItem> get _listItems => _app.zapListFor(_item);

  void _showList() {
    // Nothing to switch between, so the panel would be an empty overlay.
    if (_listVisible || _listItems.length < 2) return;
    setState(() {
      _listVisible = true;
      _controlsVisible = true;
    });
    _restartListTimer();
    _restartHideTimer();
    // Open on the channel being watched rather than at the top of 16,000.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _hideList() {
    if (!_listVisible) return;
    _listTimer?.cancel();
    setState(() => _listVisible = false);
    _restartHideTimer();
  }

  void _toggleList() => _listVisible ? _hideList() : _showList();

  void _restartListTimer() {
    _listTimer?.cancel();
    _listTimer = Timer(_listHideDelay, () {
      if (mounted && _playing) _hideList();
    });
  }

  void _scrollToCurrent() {
    if (!_listScroll.hasClients) return;
    final index = _listItems.indexWhere((e) => e.id == _item.id);
    if (index < 0) return;
    const rowHeight = _ChannelList.rowHeight;
    final viewport = _listScroll.position.viewportDimension;
    final target = (index * rowHeight) - (viewport / 2) + (rowHeight / 2);
    _listScroll.jumpTo(
      target.clamp(0.0, _listScroll.position.maxScrollExtent),
    );
  }

  /// Switches without leaving playback, which is the point of the list.
  void _playFromList(MediaItem item) {
    _restartListTimer();
    if (item.id == _item.id) {
      _hideList();
      return;
    }
    _recordProgress();
    setState(() => _item = item);
    _open(item);
    // Let the new name register, then get out of the way.
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _hideList();
    });
  }

  // --- Playback actions -----------------------------------------------------

  void _togglePlay() {
    _player.playOrPause();
    _poke();
  }

  void _seekBy(Duration delta) {
    // Works wherever mpv reports a duration, which covers films and any live
    // stream with a DVR window. A plain live feed reports none, so this is a
    // no-op there without a separate check.
    if (_duration <= Duration.zero) return;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    _player.seek(target);
    _poke();
  }

  /// Decides what a double-tap means from where it landed: the outer thirds
  /// skip, the middle third plays or pauses.
  void _handleDoubleTap(double width) {
    final x = _lastTapPosition?.dx;
    final zone = width / 3;
    if (x == null || (x >= zone && x <= width - zone)) {
      _togglePlay();
      return;
    }
    _skip(forward: x > zone);
  }

  /// One skip step, accumulating into the visible burst when taps come in
  /// quick succession.
  void _skip({required bool forward}) {
    _poke();
    if (_duration <= Duration.zero) return;

    final step = _app.settings.skipSeconds;
    setState(() {
      // A tap on the other side starts a fresh count rather than subtracting.
      if (!_burstVisible || forward != _burstForward) _burstSeconds = 0;
      _burstForward = forward;
      _burstSeconds += step;
      _burstVisible = true;
    });
    _seekBy(Duration(seconds: forward ? step : -step));

    _burstTimer?.cancel();
    _burstTimer = Timer(_burstWindow, () {
      if (mounted) setState(() => _burstVisible = false);
    });
  }

  void _setVolume(double value) {
    final v = value.clamp(0.0, 100.0);
    _player.setVolume(v);
    setState(() {
      _volume = v;
      _muted = v == 0;
    });
    _poke();
  }

  void _toggleMute() {
    if (_muted || _volume == 0) {
      _player.setVolume(_volume == 0 ? 100 : _volume);
      setState(() => _muted = false);
    } else {
      _player.setVolume(0);
      setState(() => _muted = true);
    }
    _poke();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(true);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } else {
      await _exitFullscreenChrome();
    }
    _poke();
  }

  Future<void> _exitFullscreenChrome() async {
    if (Platform.isWindows) {
      await windowManager.setFullScreen(false);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// Moves [offset] places through the current channel's own category.
  void _zap(int offset) {
    // The outgoing item keeps its position before we move away from it.
    _recordProgress();
    final list = _app.zapListFor(_item);
    if (list.length < 2) return;
    final index = list.indexWhere((e) => e.id == _item.id);
    if (index < 0) return;
    final next = list[(index + offset) % list.length];
    setState(() => _item = next);
    _open(next);
    _poke();
  }

  Future<void> _close() async {
    if (_fullscreen) {
      await _toggleFullscreen();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  // --- Keyboard -------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _poke();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
      case LogicalKeyboardKey.arrowRight:
        if (_listVisible) {
          _hideList();
        } else {
          _skip(forward: true);
        }
      case LogicalKeyboardKey.arrowLeft:
        // On a remote the left edge is where the list lives, so pressing
        // into it opens the list rather than seeking.
        if (!_listVisible && _listItems.length > 1 && _isLive) {
          _showList();
        } else if (_listVisible) {
          // Already open: leave the arrows to the list's own focus.
          _restartListTimer();
        } else {
          _skip(forward: false);
        }
      case LogicalKeyboardKey.arrowUp:
        _setVolume(_volume + 5);
      case LogicalKeyboardKey.arrowDown:
        _setVolume(_volume - 5);
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
      case LogicalKeyboardKey.keyM:
        _toggleMute();
      case LogicalKeyboardKey.keyL:
      case LogicalKeyboardKey.contextMenu:
        _toggleList();
      case LogicalKeyboardKey.escape:
        // Closes the list first, then fullscreen, then the player: one step
        // back at a time rather than dropping out of everything at once.
        if (_listVisible) {
          _hideList();
        } else {
          _close();
        }
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.pageUp:
      case LogicalKeyboardKey.channelUp:
        _zap(1);
      case LogicalKeyboardKey.keyP:
      case LogicalKeyboardKey.pageDown:
      case LogicalKeyboardKey.channelDown:
        _zap(-1);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back peels off one layer at a time: the list, then fullscreen, then
      // the player itself.
      canPop: !_fullscreen && !_listVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_listVisible) {
          _hideList();
        } else if (_fullscreen) {
          _toggleFullscreen();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onHover: (_) => _poke(),
            cursor: _controlsVisible
                ? SystemMouseCursors.basic
                : SystemMouseCursors.none,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    onTap: _toggleControls,
                    onDoubleTapDown: (d) => _lastTapPosition = d.localPosition,
                    onDoubleTap: () => _handleDoubleTap(constraints.maxWidth),
                    // A swipe in from the left edge opens the list; a swipe
                    // back out closes it.
                    onHorizontalDragEnd: (details) {
                      final v = details.primaryVelocity ?? 0;
                      if (v > 320 && !_listVisible && _listItems.length > 1) {
                        _showList();
                      } else if (v < -320 && _listVisible) {
                        _hideList();
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: ColoredBox(
                      color: Colors.black,
                      child: Video(
                        controller: _controller,
                        controls: NoVideoControls,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                if (_error != null) _errorLayer(),
                if (_error == null && _buffering) const _BufferingLayer(),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _burstVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: _SkipBurst(
                        forward: _burstForward,
                        seconds: _burstSeconds,
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _controlsLayer(),
                  ),
                ),
                _ChannelList(
                  visible: _listVisible,
                  items: _listItems,
                  currentId: _item.id,
                  controller: _listScroll,
                  isFavorite: _app.isFavorite,
                  onSelected: _playFromList,
                  onClose: _hideList,
                  onInteract: _restartListTimer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorLayer() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.86),
      child: StatusView(
        icon: Icons.sensors_off_rounded,
        title: 'This stream will not play',
        message: _error,
        isError: true,
        action: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => _open(_item),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlsLayer() {
    return Column(
      children: [
        _TopBar(
          title: _item.name,
          subtitle: _item.group,
          isLive: _isLive,
          onBack: _close,
          onShowList: _listItems.length > 1 ? _toggleList : null,
          listOpen: _listVisible,
          trailing: _TrackMenus(
            tracks: _tracks,
            active: _activeTrack,
            onAudio: (t) {
              _player.setAudioTrack(t);
              _poke();
            },
            onSubtitle: (t) {
              _player.setSubtitleTrack(t);
              _poke();
            },
          ),
        ),
        const Spacer(),
        _BottomBar(
          isLive: _isLive,
          playing: _playing,
          position: _position,
          duration: _duration,
          volume: _volume,
          muted: _muted || _volume == 0,
          fullscreen: _fullscreen,
          canZap: _app.zapListFor(_item).length > 1,
          onTogglePlay: _togglePlay,
          onSeek: (d) {
            _player.seek(d);
            _poke();
          },
          onVolume: _setVolume,
          onToggleMute: _toggleMute,
          onToggleFullscreen: _toggleFullscreen,
          onPrevious: () => _zap(-1),
          onNext: () => _zap(1),
        ),
      ],
    );
  }
}

/// `m:ss`, or `h:mm:ss` once past an hour.
String formatClock(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

// --- Overlay pieces ----------------------------------------------------------

/// The skip indicator: a dimmed rounded panel over the half that was tapped,
/// showing the running total for the current burst.
class _SkipBurst extends StatelessWidget {
  const _SkipBurst({required this.forward, required this.seconds});

  final bool forward;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    const corner = Radius.circular(280);
    return Align(
      alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 0.38,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.32),
            borderRadius: BorderRadius.horizontal(
              left: forward ? corner : Radius.zero,
              right: forward ? Radius.zero : corner,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                forward
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                size: 44,
                color: Colors.white,
              ),
              const SizedBox(height: 6),
              Text(
                '$seconds seconds',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BufferingLayer extends StatelessWidget {
  const _BufferingLayer();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Center(
        child: SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.isLive,
    required this.onBack,
    required this.trailing,
    this.onShowList,
    this.listOpen = false,
  });

  final String title;
  final String? subtitle;
  final bool isLive;
  final VoidCallback onBack;
  final Widget trailing;

  /// Null when there is nothing else in this category to switch to.
  final VoidCallback? onShowList;
  final bool listOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 6,
        left: 6,
        right: 10,
        bottom: 22,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.78), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            tooltip: 'Back',
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (isLive) ...[const LiveBadge(), const SizedBox(width: 8)],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                if ((subtitle ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onShowList case final show?)
            IconButton(
              onPressed: show,
              tooltip: listOpen ? 'Hide the list (L)' : 'Show the list (L)',
              icon: Icon(
                listOpen
                    ? Icons.playlist_remove_rounded
                    : Icons.playlist_play_rounded,
                color: Colors.white,
              ),
            ),
          trailing,
        ],
      ),
    );
  }
}

/// The channel list that slides over the video while it keeps playing.
///
/// Dismissed by a tap on the video, Back, Escape, or on its own after a
/// while — picking the next thing to watch should not mean leaving what is
/// already on.
class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.visible,
    required this.items,
    required this.currentId,
    required this.controller,
    required this.isFavorite,
    required this.onSelected,
    required this.onClose,
    required this.onInteract,
  });

  static const rowHeight = 58.0;
  static const _width = 340.0;

  final bool visible;
  final List<MediaItem> items;
  final String currentId;
  final ScrollController controller;
  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onSelected;
  final VoidCallback onClose;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    // Built even while hidden so it can animate in, so an empty catalog must
    // not reach the panel — it indexes the list to find the current item.
    if (items.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final width = _width.clamp(0.0, MediaQuery.sizeOf(context).width * 0.86);

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: Stack(
          children: [
            // Dimming the rest doubles as the tap target that closes it.
            AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: visible ? 0 : -width,
              top: 0,
              bottom: 0,
              width: width,
              child: _Panel(
                items: items,
                currentId: currentId,
                controller: controller,
                isFavorite: isFavorite,
                onSelected: onSelected,
                onClose: onClose,
                onInteract: onInteract,
                accent: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.items,
    required this.currentId,
    required this.controller,
    required this.isFavorite,
    required this.onSelected,
    required this.onClose,
    required this.onInteract,
    required this.accent,
  });

  final List<MediaItem> items;
  final String currentId;
  final ScrollController controller;
  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onSelected;
  final VoidCallback onClose;
  final VoidCallback onInteract;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final group = items
        .firstWhere(
          (e) => e.id == currentId,
          orElse: () => items.first,
        )
        .group;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.background.withValues(alpha: 0.93),
        border: const Border(right: BorderSide(color: AppTheme.outline)),
      ),
      child: SafeArea(
        right: false,
        child: Listener(
          // Any touch inside keeps it open; it only times out when ignored.
          onPointerDown: (_) => onInteract(),
          onPointerSignal: (_) => onInteract(),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            (group ?? '').trim().isEmpty
                                ? 'Up next'
                                : group!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${items.length} items',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onClose,
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  // Fixed height is what lets the current row be scrolled to
                  // without measuring 16,000 of them.
                  itemExtent: _ChannelList.rowHeight,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final current = item.id == currentId;
                    return Material(
                      color: current
                          ? accent.withValues(alpha: 0.16)
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () => onSelected(item),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              ChannelLogo(
                                url: item.logo,
                                name: item.name,
                                size: 34,
                                radius: 8,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.25,
                                    fontWeight: current
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: current ? accent : Colors.white,
                                  ),
                                ),
                              ),
                              if (isFavorite(item.id))
                                const Icon(
                                  Icons.star_rounded,
                                  size: 15,
                                  color: Color(0xFFFFC53D),
                                ),
                              if (current)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.equalizer_rounded,
                                    size: 16,
                                    color: accent,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Audio and subtitle pickers, hidden when a stream offers no choice.
class _TrackMenus extends StatelessWidget {
  const _TrackMenus({
    required this.tracks,
    required this.active,
    required this.onAudio,
    required this.onSubtitle,
  });

  final Tracks tracks;
  final Track active;
  final ValueChanged<AudioTrack> onAudio;
  final ValueChanged<SubtitleTrack> onSubtitle;

  @override
  Widget build(BuildContext context) {
    final audio = tracks.audio.where((t) => t.id != 'auto').toList();
    final subtitles = tracks.subtitle;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (audio.length > 1)
          PopupMenuButton<AudioTrack>(
            tooltip: 'Audio track',
            icon: const Icon(Icons.multitrack_audio_rounded, color: Colors.white),
            onSelected: onAudio,
            itemBuilder: (context) => [
              for (final track in audio)
                CheckedPopupMenuItem<AudioTrack>(
                  value: track,
                  checked: track.id == active.audio.id,
                  child: Text(_label(track.title, track.language, track.id)),
                ),
            ],
          ),
        if (subtitles.length > 1)
          PopupMenuButton<SubtitleTrack>(
            tooltip: 'Subtitles',
            icon: const Icon(Icons.subtitles_rounded, color: Colors.white),
            onSelected: onSubtitle,
            itemBuilder: (context) => [
              for (final track in subtitles)
                CheckedPopupMenuItem<SubtitleTrack>(
                  value: track,
                  checked: track.id == active.subtitle.id,
                  child: Text(
                    track.id == 'no'
                        ? 'Off'
                        : _label(track.title, track.language, track.id),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  static String _label(String? title, String? language, String id) {
    final parts = [
      if ((title ?? '').trim().isNotEmpty) title!.trim(),
      if ((language ?? '').trim().isNotEmpty) language!.trim().toUpperCase(),
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.isLive,
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.canZap,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    required this.onPrevious,
    required this.onNext,
  });

  final bool isLive;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool muted;
  final bool fullscreen;
  final bool canZap;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < 560;
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 26,
        bottom: MediaQuery.paddingOf(context).bottom + 8,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.82), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Shown whenever there is something to scrub through, which
          // includes a live stream with a DVR window.
          if (duration > Duration.zero)
            Row(
              children: [
                const SizedBox(width: 8),
                Text(formatClock(position), style: _timeStyle),
                Expanded(
                  child: Slider(
                    value: position.inMilliseconds
                        .clamp(0, duration.inMilliseconds)
                        .toDouble(),
                    max: duration.inMilliseconds.toDouble(),
                    onChanged: (v) =>
                        onSeek(Duration(milliseconds: v.round())),
                  ),
                ),
                Text(formatClock(duration), style: _timeStyle),
                const SizedBox(width: 8),
              ],
            ),
          Row(
            children: [
              if (canZap)
                _Btn(
                  icon: Icons.skip_previous_rounded,
                  tooltip: 'Previous (P)',
                  onPressed: onPrevious,
                ),
              _Btn(
                icon: playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
                onPressed: onTogglePlay,
                size: 34,
              ),
              if (canZap)
                _Btn(
                  icon: Icons.skip_next_rounded,
                  tooltip: 'Next (N)',
                  onPressed: onNext,
                ),
              _Btn(
                icon: muted
                    ? Icons.volume_off_rounded
                    : volume < 50
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                tooltip: 'Mute (M)',
                onPressed: onToggleMute,
              ),
              if (!isNarrow)
                SizedBox(
                  width: 108,
                  child: Slider(
                    value: muted ? 0 : volume,
                    max: 100,
                    onChanged: onVolume,
                  ),
                ),
              const Spacer(),
              if (isLive && duration <= Duration.zero)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(formatClock(position), style: _timeStyle),
                ),
              _Btn(
                icon: fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: 'Fullscreen (F)',
                onPressed: onToggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static const _timeStyle = TextStyle(
    fontSize: 12.5,
    color: Colors.white,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 26,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: size,
      color: Colors.white,
      icon: Icon(icon),
    );
  }
}
