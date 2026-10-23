import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_info.dart';
import 'data/local_store.dart';
import 'data/repository.dart';
import 'state/app_state.dart';
import 'ui/root_page.dart';
import 'ui/theme.dart';
import 'ui/widgets/window_chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Boots libmpv. Must run before any Player is constructed.
  MediaKit.ensureInitialized();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        // Comfortably inside a 1366x768 work area, which the old 1340x820
        // default was not.
        size: Size(1180, 720),
        minimumSize: Size(900, 560),
        center: true,
        title: AppInfo.name,
        // The native caption renders blank under window_manager, so the app
        // draws its own; see WindowChrome.
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        // Deliberately no show() here. The runner shows the window on its
        // first frame, after it has recalculated the frame that hiding the
        // native caption invalidated — showing it from Dart first puts the
        // stale caption strip on screen for a moment.
        await windowManager.focus();
      },
    );
  }

  final store = await LocalStore.open();
  final state = AppState(store, Repository(store));

  runApp(
    ChangeNotifierProvider<AppState>.value(value: state, child: const MyTvApp()),
  );

  // Reads saved playlists and loads the last one. Deliberately not awaited so
  // the first frame paints immediately.
  state.bootstrap();
}

class MyTvApp extends StatelessWidget {
  const MyTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const RootPage(),
      scrollBehavior: const _DragAnywhereScrollBehavior(),
      // Wrapped above the navigator so the title bar stays put across routes,
      // including the full-screen player.
      builder: (context, child) =>
          WindowChrome(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Long channel lists should be draggable with the mouse on Windows, not only
/// with the wheel or scrollbar.
class _DragAnywhereScrollBehavior extends MaterialScrollBehavior {
  const _DragAnywhereScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}
