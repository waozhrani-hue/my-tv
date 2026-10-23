import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'add_source_page.dart';
import 'widgets/update_card.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final settings = state.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _SectionTitle('Playlists'),
              for (final source in state.sources)
                _SourceRow(source: source, isCurrent: source.id == state.current?.id),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddSourcePage()),
                ),
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('Add playlist'),
              ),

              const SizedBox(height: 28),
              _SectionTitle('Playback'),
              _Card(
                children: [
                  ListTile(
                    title: const Text('Live stream format'),
                    subtitle: Text(
                      'Xtream panels serve live channels in both. Switch if '
                      'channels refuse to start.\nCurrently ${settings.liveContainer.label}',
                      style: _subtitleStyle,
                    ),
                    trailing: SegmentedButton<LiveContainer>(
                      segments: const [
                        ButtonSegment(value: LiveContainer.ts, label: Text('TS')),
                        ButtonSegment(value: LiveContainer.hls, label: Text('HLS')),
                      ],
                      selected: {settings.liveContainer},
                      showSelectedIcon: false,
                      onSelectionChanged: (set) => state.updateSettings(
                        settings.copyWith(liveContainer: set.first),
                      ),
                    ),
                  ),
                  const Divider(),
                  SwitchListTile(
                    value: settings.resumePlayback,
                    onChanged: (v) => state.updateSettings(
                      settings.copyWith(resumePlayback: v),
                    ),
                    title: const Text('Resume where you left off'),
                    subtitle: const Text(
                      'Films reopen at the position you stopped at. Live '
                      'channels always start at the current broadcast.',
                      style: _subtitleStyle,
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    title: const Text('Skip step'),
                    subtitle: const Text(
                      'How far a double-tap on the left or right of the video '
                      'moves, and how far the arrow keys move.',
                      style: _subtitleStyle,
                    ),
                    trailing: DropdownButton<int>(
                      value: settings.skipSeconds,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final s in Settings.skipChoices)
                          DropdownMenuItem(value: s, child: Text('$s s')),
                      ],
                      onChanged: (v) => v == null
                          ? null
                          : state.updateSettings(
                              settings.copyWith(skipSeconds: v),
                            ),
                    ),
                  ),
                  const Divider(),
                  SwitchListTile(
                    value: settings.hardwareDecoding,
                    onChanged: (v) => state.updateSettings(
                      settings.copyWith(hardwareDecoding: v),
                    ),
                    title: const Text('Hardware decoding'),
                    subtitle: const Text(
                      'Uses the GPU. Turn off if video is black or stutters.',
                      style: _subtitleStyle,
                    ),
                  ),
                  const Divider(),
                  _BufferSlider(
                    megabytes: settings.bufferMegabytes,
                    onChanged: (v) => state.updateSettings(
                      settings.copyWith(bufferMegabytes: v),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 28),
              _SectionTitle('Network'),
              _Card(
                children: [
                  _UserAgentTile(
                    value: settings.userAgent,
                    onChanged: (v) => state.updateSettings(
                      settings.copyWith(
                        userAgent: v.trim().isEmpty
                            ? Settings.defaultUserAgent
                            : v.trim(),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 28),
              _SectionTitle('Updates'),
              const UpdateCard(),

              const SizedBox(height: 28),
              _SectionTitle('About'),
              _Card(
                children: [
                  const ListTile(
                    title: Text(AppInfo.name),
                    subtitle: Text(
                      '${AppInfo.edition}\n'
                      'IPTV stream player · version ${AppInfo.version}',
                      style: _subtitleStyle,
                    ),
                  ),
                  const Divider(),
                  const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('No content is included'),
                    subtitle: Text(
                      'This app plays only the playlists you add. You are '
                      'responsible for having the right to use them.',
                      style: _subtitleStyle,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _subtitleStyle = TextStyle(fontSize: 12.5, height: 1.4);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 10, bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(children: children),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.isCurrent});

  final PlaylistSource source;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          source.kind == SourceKind.xtream
              ? Icons.dns_rounded
              : source.isLocalFile
                  ? Icons.description_outlined
                  : Icons.link_rounded,
          color: isCurrent ? scheme.primary : null,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(source.name, overflow: TextOverflow.ellipsis),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  'ACTIVE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          source.kind == SourceKind.xtream
              ? '${source.host} · ${source.username}'
              : source.url ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined, size: 19),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AddSourcePage(existing: source),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
              onPressed: () => _confirmRemove(context, state),
            ),
          ],
        ),
        onTap: isCurrent ? null : () => state.selectSource(source.id),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, AppState state) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${source.name}"?'),
        content: const Text(
          'The playlist and its cached channel list are deleted from this '
          'device. Your favourites are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.removeSource(source.id);
  }
}

class _BufferSlider extends StatefulWidget {
  const _BufferSlider({required this.megabytes, required this.onChanged});

  final int megabytes;
  final ValueChanged<int> onChanged;

  @override
  State<_BufferSlider> createState() => _BufferSliderState();
}

class _BufferSliderState extends State<_BufferSlider> {
  late double _value = widget.megabytes.toDouble();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Buffer size')),
              Text(
                '${_value.round()} MB',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          const Text(
            'A larger buffer smooths over unstable connections at the cost of '
            'a slower start.',
            style: TextStyle(fontSize: 12.5, height: 1.4),
          ),
          Slider(
            value: _value,
            min: 4,
            max: 128,
            divisions: 31,
            label: '${_value.round()} MB',
            onChanged: (v) => setState(() => _value = v),
            // Applying on release avoids rewriting settings on every frame.
            onChangeEnd: (v) => widget.onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}

class _UserAgentTile extends StatefulWidget {
  const _UserAgentTile({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_UserAgentTile> createState() => _UserAgentTileState();
}

class _UserAgentTileState extends State<_UserAgentTile> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('User-Agent'),
          const SizedBox(height: 4),
          const Text(
            'Sent with every playlist and stream request. Some providers only '
            'answer a player they recognise.',
            style: TextStyle(fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Reset to default',
                icon: const Icon(Icons.restart_alt_rounded, size: 19),
                onPressed: () {
                  _controller.text = Settings.defaultUserAgent;
                  widget.onChanged(Settings.defaultUserAgent);
                },
              ),
            ),
            onSubmitted: widget.onChanged,
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              if (_controller.text.trim() != widget.value) {
                widget.onChanged(_controller.text);
              }
            },
          ),
        ],
      ),
    );
  }
}
