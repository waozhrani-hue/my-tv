import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../data/update_service.dart';
import '../../state/app_state.dart';

/// Checks GitHub for a newer build and, when there is one, downloads it and
/// opens the installer.
///
/// Nothing installs without the user: Android shows its own package-installer
/// confirmation, and on Windows the setup program opens normally.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

enum _Stage { idle, checking, downloading, ready }

class _UpdateCardState extends State<UpdateCard> {
  _Stage _stage = _Stage.idle;
  double _progress = 0;
  String? _message;
  bool _isError = false;
  File? _downloaded;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final release = state.availableUpdate;
    final scheme = Theme.of(context).colorScheme;

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

            if (_stage == _Stage.downloading) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: _progress, minHeight: 6),
              ),
              const SizedBox(height: 6),
              Text(
                'Downloading ${(_progress * 100).round()}%'
                '${_sizeLabel(release?.assetBytes)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],

            if (_message != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: (_isError ? scheme.error : scheme.primary)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_isError ? scheme.error : scheme.primary)
                        .withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: _isError ? scheme.error : scheme.primary,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 14),
            Row(
              children: [
                if (release == null)
                  OutlinedButton.icon(
                    onPressed: _stage == _Stage.checking ? null : _check,
                    icon: _stage == _Stage.checking
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
                    onPressed: _stage == _Stage.downloading
                        ? null
                        : () => _stage == _Stage.ready
                              ? _install()
                              : _downloadAndInstall(release),
                    icon: Icon(
                      _stage == _Stage.ready
                          ? Icons.install_mobile_rounded
                          : Icons.download_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _stage == _Stage.ready
                          ? 'Install now'
                          : 'Download and install',
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _stage == _Stage.downloading ? null : _check,
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
      _stage = _Stage.checking;
      _message = null;
      _downloaded = null;
    });
    final state = context.read<AppState>();
    try {
      final release = await state.checkForUpdate();
      if (!mounted) return;
      if (release == null) {
        _say('You already have the newest published build.');
      } else {
        setState(() => _message = null);
      }
    } finally {
      if (mounted) setState(() => _stage = _Stage.idle);
    }
  }

  Future<void> _downloadAndInstall(AppRelease release) async {
    final service = context.read<AppState>().updates;

    // Ask for the install permission first, so the download is not wasted.
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

    setState(() {
      _stage = _Stage.downloading;
      _progress = 0;
      _message = null;
    });

    try {
      final file = await service.download(
        release,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloaded = file;
        _stage = _Stage.ready;
      });
      await _install();
    } on UpdateException catch (e) {
      if (mounted) setState(() => _stage = _Stage.idle);
      _say(e.message, error: true);
    } catch (e) {
      if (mounted) setState(() => _stage = _Stage.idle);
      _say('The download failed — $e', error: true);
    }
  }

  Future<void> _install() async {
    final file = _downloaded;
    if (file == null) return;
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
