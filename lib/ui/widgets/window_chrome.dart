import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_info.dart';
import '../theme.dart';

/// A title bar drawn by the app itself.
///
/// The native Windows caption comes up blank under window_manager — no title,
/// no minimise or maximise buttons — so the app supplies its own. It also
/// looks right against a dark media UI, which the stock light caption does
/// not. On every other platform this is a pass-through.
class WindowChrome extends StatefulWidget {
  const WindowChrome({super.key, required this.child});

  final Widget child;

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> with WindowListener {
  static const _barHeight = 36.0;

  /// Implemented in windows/runner/flutter_window.cpp.
  ///
  /// window_manager's `minimize()` does nothing on this window — verified
  /// against a build where the same button wiring worked for maximise and
  /// close — and its `isMaximized()` misreports once the native caption is
  /// hidden, so restoring never fired. Win32 handles both correctly, so these
  /// two go straight there.
  static const _native = MethodChannel('com.mytv.my_tv/window');

  var _maximized = false;
  var _fullscreen = false;

  @override
  void initState() {
    super.initState();
    if (!WindowChrome.isSupported) return;
    windowManager.addListener(this);
    _sync();
    // Done after the first frame, by which point window_manager has applied
    // the hidden title bar; this is what clears the stale caption strip it
    // leaves behind.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFrame());
  }

  Future<void> _refreshFrame() async {
    try {
      await _native.invokeMethod<void>('refreshFrame');
    } on PlatformException {
      // Cosmetic only; the window works either way.
    } on MissingPluginException {
      // Running against a build without the native channel.
    }
  }

  @override
  void dispose() {
    if (WindowChrome.isSupported) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    final maximized = await _isMaximized();
    final fullscreen = await windowManager.isFullScreen();
    if (!mounted) return;
    setState(() {
      _maximized = maximized;
      _fullscreen = fullscreen;
    });
  }

  Future<bool> _isMaximized() async {
    try {
      return await _native.invokeMethod<bool>('isMaximized') ?? false;
    } on PlatformException {
      return windowManager.isMaximized();
    } on MissingPluginException {
      return windowManager.isMaximized();
    }
  }

  Future<void> _minimize() async {
    try {
      await _native.invokeMethod<void>('minimize');
    } on PlatformException {
      await windowManager.minimize();
    } on MissingPluginException {
      await windowManager.minimize();
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowEnterFullScreen() => setState(() => _fullscreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullscreen = false);

  Future<void> _toggleMaximize() async {
    try {
      final nowMaximized = await _native.invokeMethod<bool>('toggleMaximize');
      if (nowMaximized != null && mounted) {
        setState(() => _maximized = nowMaximized);
      }
      return;
    } on PlatformException {
      // Fall through to the plugin.
    } on MissingPluginException {
      // Fall through to the plugin.
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowChrome.isSupported) return widget.child;
    // Fullscreen playback should be exactly that.
    if (_fullscreen) return widget.child;

    return Column(
      children: [
        SizedBox(
          height: _barHeight,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: AppTheme.background,
              border: Border(
                bottom: BorderSide(color: AppTheme.outline, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _toggleMaximize,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          children: [
                            Icon(
                              Icons.live_tv_rounded,
                              size: 15,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              AppInfo.name,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.1,
                                color: Colors.white.withValues(alpha: 0.72),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _CaptionButton(
                  icon: Icons.remove,
                  tooltip: 'Minimise',
                  onPressed: _minimize,
                ),
                _CaptionButton(
                  icon: _maximized
                      ? Icons.filter_none_rounded
                      : Icons.crop_square_rounded,
                  iconSize: _maximized ? 12 : 15,
                  tooltip: _maximized ? 'Restore' : 'Maximise',
                  onPressed: _toggleMaximize,
                ),
                _CaptionButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  danger: true,
                  onPressed: windowManager.close,
                ),
              ],
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 15,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = !_hovered
        ? Colors.transparent
        : widget.danger
            ? const Color(0xFFC42B1C)
            : Colors.white.withValues(alpha: 0.09);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: double.infinity,
            color: background,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: Colors.white.withValues(
                alpha: _hovered && widget.danger ? 1 : 0.8,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
