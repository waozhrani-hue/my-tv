# My TV — إصدار خاص (لمعاليكم)

An IPTV stream player for Windows and Android, built from one Flutter codebase.
Playback runs on **libmpv** through [`media_kit`](https://pub.dev/packages/media_kit),
so the formats IPTV providers actually serve — MPEG-TS over HTTP, HLS, RTMP,
RTSP — play without per-format special cases.

The app ships no channels and no content. It plays the playlists you add.

The product name and edition live in one place, [`lib/app_info.dart`](lib/app_info.dart),
which feeds the window title, the welcome screen and the About section. The
Android launcher label is `android/app/src/main/res/values/strings.xml`, and
the Windows file properties are in `windows/runner/Runner.rc` (ASCII there, as
the resource block is compiled in a Latin-1 codepage).

## Features

- **Two source types** — an M3U/M3U8 playlist (by URL or from a local file) or
  an Xtream Codes account (server, username, password).
- **Several playlists** side by side, switched from the header menu.
- **Live TV and Movies** — Xtream VOD alongside live channels.
- **Grid or list**, switched from the header and remembered per section:
  channels default to a dense list, films to poster art.
- **Resume where you left off** — a film reopens at the position it was
  stopped at, with a progress bar across its tile and a "start over" action on
  the resume notice. Live channels always join the current broadcast.
- **Categories, search, favourites and watch history**, all filterable.
- **Player** — play/pause, volume, mute, audio-track and subtitle pickers,
  fullscreen, and next/previous zapping inside the current category.
- **Double-tap to skip**, as on YouTube: the left third of the video jumps
  back, the right third jumps forward, the middle third plays or pauses.
  Repeated taps inside 900 ms add up into one indicator — 10, 20, 30 — rather
  than flashing separately. The step is configurable (5/10/15/30 s) and the
  arrow keys use the same step and show the same indicator. Seeking is offered
  wherever mpv reports a duration, so a live stream with a DVR window gets a
  scrub bar too; a plain live feed reports none and the gesture does nothing.
- **Offline-first** — a parsed playlist is cached for 12 hours, so launching
  does not wait on the network. A failed refresh falls back to the cache rather
  than showing nothing.
- **Provider quirks handled** — per-channel `User-Agent`/`Referer` from
  `#EXTVLCOPT`, a configurable global User-Agent, a TS/HLS switch for Xtream
  live URLs, and cleartext HTTP allowed on Android.

## Requirements

| | |
|---|---|
| Flutter | 3.44.8 (Dart 3.12.2) |
| Android | SDK platform 36, build-tools 36.1.0, JDK 17+ |
| Windows | Visual Studio Build Tools with the **Desktop development with C++** workload |
| Windows | Developer Mode enabled — Flutter needs symlinks to build plugins |

## Build

```bash
flutter pub get

# Android — one APK that installs on any device, in
# build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release

# Or smaller per-architecture APKs, if you know the target
flutter build apk --release --split-per-abi

# Windows — build/windows/x64/runner/Release/
flutter build windows --release

# Windows installer — build/installer/MyTV-Setup-<version>.exe
# (needs Inno Setup 6: winget install JRSoftware.InnoSetup)
ISCC.exe installer\my-tv.iss

# Run on a connected device or the desktop
flutter run -d windows
flutter run -d <android-device-id>

flutter test
flutter analyze
```

### Android signing

Release builds are signed with the keystore described in
`android/key.properties`, which is **not** committed. If that file is missing,
the build falls back to the debug keys so a fresh clone still runs.

To create your own:

```bash
keytool -genkeypair -v -keystore android/app/mytv-release.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias mytv
```

Then write `android/key.properties`:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=mytv
storeFile=mytv-release.jks
```

Back the keystore up. Losing it means no future build can install over an
existing copy of the app.

## Project layout

```
lib/
  main.dart                 Entry point: libmpv init, window setup, DI
  data/
    models.dart             PlaylistSource, MediaItem, Catalog, Settings
    m3u_parser.dart         Extended-M3U parser (#EXTINF, #EXTGRP, #EXTVLCOPT)
    xtream_client.dart      player_api.php client and stream-URL builder
    repository.dart         Source -> Catalog, with the on-disk cache
    local_store.dart        Atomic JSON persistence
  state/
    app_state.dart          Single ChangeNotifier the whole UI reads
  ui/
    root_page.dart          Onboarding vs. browser
    add_source_page.dart    Add/edit a playlist, with an Xtream "Test" button
    browse_page.dart        Rail/categories/search, channel list, poster grid
    player_page.dart        Playback surface and controls
    settings_page.dart      Playlists, playback, network
    theme.dart              Dark theme
    widgets/common.dart     Logo, poster fallback, status and loading views
    widgets/window_chrome.dart  Custom Windows title bar
test/                       Parser, Xtream client (mocked HTTP), model JSON
```

### Why the Windows title bar is hand-drawn

Under `window_manager` the native caption comes up blank — no title text and
no minimise or maximise buttons, although the window styles still carry
`WS_MINIMIZEBOX` and `WS_MAXIMIZEBOX`. Rather than fight it, the app hides the
native bar (`TitleBarStyle.hidden`) and draws its own in
`lib/ui/widgets/window_chrome.dart`, which also lets it match the dark theme.
It is installed through `MaterialApp.builder` so it sits above the navigator
and survives route changes, and hides itself during fullscreen playback.

### Sharing the Windows build

`MyTV.exe` does not run on its own — it needs `libmpv-2.dll`,
`flutter_windows.dll`, the plugin DLLs and the `data/` directory beside it. So
the thing to hand someone is the installer from `installer/my-tv.iss`, which
packs the whole Release folder into one file, installs per user (no
administrator rights), and leaves an entry in Add or Remove Programs.

The installer is not code-signed, so Windows SmartScreen shows a
"Windows protected your PC" prompt on first run; **More info → Run anyway**
gets past it. Signing it needs a code-signing certificate.

### Icons

`tool/make-icons.ps1` draws every icon from one vector description — Android
legacy mipmaps, the adaptive foreground, the Android TV banner, and the
multi-size Windows `.ico`. Re-run it after changing the mark:

```powershell
pwsh tool/make-icons.ps1
```

State lives in one `AppState` exposed with `provider`. There is no router: the
app is four screens deep at most and `Navigator.push` is clearer here than a
route table.

## Settings that matter

- **Live stream format (TS / HLS)** — Xtream panels build live URLs as either
  `…/live/user/pass/<id>.ts` or `.m3u8`, and support differs per panel. If
  channels will not start, switch this first. Changing it clears the cached
  catalog, because the stream URLs are stored in it.
- **Buffer size** — the main lever on unstable providers. Bigger absorbs more
  jitter and starts more slowly. Default 32 MB.
- **Hardware decoding** — on by default. Turn it off if video is black or
  stutters on a particular machine.
- **User-Agent** — some providers answer only a player they recognise. Default
  is a VLC string; a per-playlist override is available in the playlist form,
  and `#EXTVLCOPT` lines in an M3U take precedence for their own channel.

## Keyboard shortcuts (player)

| Key | Action |
|---|---|
| `Space` / `K` | Play / pause |
| `←` / `→` | Skip back / forward by the configured step |
| `↑` / `↓` | Volume ±5 |
| `F` | Fullscreen |
| `M` | Mute |
| `N` / `Page Up` | Next channel in category |
| `P` / `Page Down` | Previous channel in category |
| `Esc` | Leave fullscreen, or close the player |

The same actions are bound to the Android TV remote's channel and media keys,
and the manifest declares `LEANBACK_LAUNCHER`, so the APK installs and launches
on Android TV boxes as well as phones.

## Where data is stored

Everything is local, under the platform's application-support directory. On
Windows that path is derived from the executable's version info, so it follows
`ProductName` in `windows/runner/Runner.rc`: `%APPDATA%\com.mytv\My TV\data`.
Changing that string moves the folder, so existing data has to be moved with
it.

| File | Contents |
|---|---|
| `sources.json` | Configured playlists, including Xtream credentials |
| `favorites.json` | Favourite item ids |
| `recents.json` | Watch history |
| `progress.json` | Where each film was left off |
| `settings.json` | Preferences |
| `catalog_<id>.json` | Cached parsed playlist |

Credentials are stored in plain JSON, as every IPTV client on these platforms
does, because the stream URLs themselves embed them. Treat the directory as
sensitive.

## Legal

This player contains no streams, playlists or credentials. You are responsible
for having the right to access whatever you add to it.
