import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// Films kept on the device, with what is still arriving at the top.
class DownloadsView extends StatelessWidget {
  const DownloadsView({super.key, required this.onPlay});

  final ValueChanged<MediaItem> onPlay;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final records = state.downloads.records;

    if (records.isEmpty) {
      return const StatusView(
        icon: Icons.download_for_offline_outlined,
        title: 'Nothing saved for offline',
        message:
            'Open a film and use Save for offline. It will play with no '
            'connection at all — on a flight, or anywhere the signal is not '
            'worth trusting.',
      );
    }

    // In progress first: that is what someone on this screen is watching.
    final sorted = [
      ...records.where((r) => r.isActive),
      ...records.where((r) => r.state == DownloadState.failed),
      ...records.where((r) => r.isComplete),
    ];

    final paused = state.downloads.isSuspended && records.any((r) => r.isActive);

    return Column(
      children: [
        if (paused) const _PausedBanner(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 16),
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (context, index) => _DownloadRow(
              record: sorted[index],
              onPlay: onPlay,
              paused: paused,
            ),
          ),
        ),
      ],
    );
  }
}

/// Explains a download that is sitting still, rather than letting it look
/// broken.
class _PausedBanner extends StatelessWidget {
  const _PausedBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline_rounded, size: 19, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Paused while something is playing. Most IPTV accounts allow '
              'one connection at a time, so downloading would stop playback '
              'working. It carries on from here when you close the player.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.record,
    required this.onPlay,
    this.paused = false,
  });

  final DownloadRecord record;
  final ValueChanged<MediaItem> onPlay;

  /// Standing aside for playback, rather than genuinely waiting its turn.
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final playable = record.isComplete;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: playable ? () => onPlay(record.item) : null,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ChannelLogo(
                    url: record.item.logo,
                    name: record.item.name,
                    size: 44,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          record.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          paused && record.isActive
                              ? 'Paused · ${formatBytes(record.receivedBytes)} '
                                    'saved so far'
                              : _subtitle(record),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: record.state == DownloadState.failed
                                ? scheme.error
                                : Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (record.isComplete)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.offline_pin_rounded,
                        size: 21,
                        color: scheme.primary,
                      ),
                    ),
                  if (record.state == DownloadState.failed)
                    IconButton(
                      tooltip: 'Try again',
                      onPressed: () => state.retryDownload(record.item.id),
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                    ),
                  IconButton(
                    tooltip: record.isComplete
                        ? 'Delete from this device'
                        : 'Cancel',
                    onPressed: () => _confirmRemove(context, state),
                    icon: Icon(
                      record.isComplete
                          ? Icons.delete_outline_rounded
                          : Icons.close_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
              if (record.isActive) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    // A paused bar holds its position; otherwise it is
                    // indeterminate until the server reports a size.
                    value: paused || record.totalBytes > 0
                        ? record.fraction
                        : null,
                    minHeight: 4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitle(DownloadRecord record) => switch (record.state) {
    DownloadState.completed =>
      'Saved · ${formatBytes(record.totalBytes)} · plays offline',
    DownloadState.queued => 'Waiting its turn',
    DownloadState.running => record.totalBytes > 0
        ? '${(record.fraction * 100).round()}% · '
              '${formatBytes(record.receivedBytes)} of '
              '${formatBytes(record.totalBytes)}'
        : 'Starting… ${formatBytes(record.receivedBytes)}',
    DownloadState.failed =>
      record.error ?? 'The download failed. Try again when you have signal.',
  };

  Future<void> _confirmRemove(BuildContext context, AppState state) async {
    final complete = record.isComplete;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(complete ? 'Delete this download?' : 'Cancel this download?'),
        content: Text(
          complete
              ? '"${record.item.name}" is removed from this device, freeing '
                    '${formatBytes(record.totalBytes)}. It stays available to '
                    'stream.'
              : 'Stops "${record.item.name}" and discards what has arrived.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(complete ? 'Delete' : 'Cancel download'),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.downloads.remove(record.item.id);
  }
}

/// `1.4 GB`, `820 MB`, `12 KB`.
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
