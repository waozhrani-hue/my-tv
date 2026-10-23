import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../data/update_service.dart';
import '../../state/app_state.dart';

/// Checks GitHub for a newer build and, when there is one, downloads it and
/// opens the installer.
///
/// The download itself lives in [AppState], not here, so leaving this screen
/// does not abandon it: come back and the progress is where it should be.
/// Nothing installs without the user — Android shows its own package-installer
/// confirmation, and on Windows the setup program opens normally.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  var _checking = false;
  String? _message;
  var _isError = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final release = state.availableUpdate;
    final scheme = Theme.of(context).colorScheme;

    final downloading = state.isDownloadingUpdate;
    final downloaded = state.downloadedUpdate;
    final error = state.downloadError ?? _message;
    final isError = state.downloadError != null || _isError;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  release == null
                      ? Icons.check_circle_outline_rounded
                      : Icons.system_update_rounded,
                  size: 20,
                  color: release == null ? null : scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    release == null
                        ? 'Version ${AppInfo.version}'
                        : 'Version ${release.version} is available',
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              release == null
                  ? state.updateChecked
                        ? 'This is the newest published build.'
                        : 'Checking for updates…'
                  : 'You are on ${AppInfo.version}.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),

            if (release != null && release.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  release.notes,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.45),
                ),
              ),
            ],

            if (downloading) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: state.downloadProgress,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Downloading ${(state.downloadProgress * 100).round()}%'
                '${_sizeLabel(release?.assetBytes)}\n'
                '${Platform.isAndroid ? 'It keeps going if you close the app — watch the notification.' : 'It keeps going if you leave this screen.'}',
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ],

            if (error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: (isError ? scheme.error : scheme.primary)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (isError ? scheme.error : scheme.primary)
                        .withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  error,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: isError ? scheme.error : scheme.primary,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 14),
            Row(
              children: [
                if (release == null)
                  OutlinedButton.icon(
                    onPressed: _checking ? null : _check,
                    icon: _checking
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Check for updates'),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: downloading
                        ? null
                        : downloaded != null
                              ? () => _install(downloaded)
                              : () => _startDownload(state),
                    icon: Icon(
                      downloaded != null
                          ? Icons.install_mobile_rounded
                          : Icons.download_rounded,
                      size: 18,
                    ),
                    label: Text(
                      downloading
                          ? 'Downloading…'
                          : downloaded != null
                                ? 'Install now'
                                : 'Download and install',
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: downloading || _checking ? null : _check,
                    child: const Text('Re-check'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _sizeLabel(int? bytes) =>
      bytes == null ? '' : ' of ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _isError = error;
    });
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
      _isError = false;
    });
    final state = context.read<AppState>();
    state.clearDownloadError();
    try {
      final release = await state.checkForUpdate();
      if (!mounted) return;
      if (release == null) {
        _say('You already have the newest published build.');
      } else {
        setState(() => _message = null);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _startDownload(AppState state) async {
    final service = state.updates;
    setState(() {
      _message = null;
      _isError = false;
    });
    state.clearDownloadError();

    // Ask for the install permission first, so a 90 MB download is not wasted
    // on a device that will refuse to install it.
    if (Platform.isAndroid && !await service.canRequestInstalls()) {
      if (!mounted) return;
      _say(
        'Android needs permission to install apps from My TV. Allow it in '
        'the screen that opens, then press Download again.',
        error: true,
      );
      await service.openInstallSettings();
      return;
    }

    final file = await state.downloadUpdate();
    if (!mounted || file == null) return;
    await _install(file);
  }

  Future<void> _install(File file) async {
    final service = context.read<AppState>().updates;
    try {
      await service.install(file);
      _say(
        Platform.isAndroid
            ? 'Confirm the install in the window Android just opened.'
            : 'The installer has started. It will close My TV to update it.',
      );
    } on UpdateException catch (e) {
      _say(e.message, error: true);
    } catch (e) {
      _say('Could not start the installer — $e', error: true);
    }
  }
}
