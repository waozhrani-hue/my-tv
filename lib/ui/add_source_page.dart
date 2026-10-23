import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';

enum SourceFormTab { m3u, xtream }

/// Form for adding a new playlist, or editing an existing one when [existing]
/// is given.
class AddSourcePage extends StatefulWidget {
  const AddSourcePage({
    super.key,
    this.initialTab = SourceFormTab.m3u,
    this.existing,
  });

  final SourceFormTab initialTab;
  final PlaylistSource? existing;

  @override
  State<AddSourcePage> createState() => _AddSourcePageState();
}

class _AddSourcePageState extends State<AddSourcePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _m3uForm = GlobalKey<FormState>();
  final _xtreamForm = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _url = TextEditingController();
  final _epg = TextEditingController();
  final _agent = TextEditingController();
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  String? _localPath;
  bool _busy = false;
  bool _showPassword = false;
  String? _message;
  bool _messageIsError = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final startTab = existing != null
        ? (existing.kind == SourceKind.xtream
              ? SourceFormTab.xtream
              : SourceFormTab.m3u)
        : widget.initialTab;
    _tabs = TabController(
      length: 2,
      initialIndex: startTab.index,
      vsync: this,
    );

    if (existing != null) {
      _name.text = existing.name;
      _agent.text = existing.userAgent ?? '';
      _epg.text = existing.epgUrl ?? '';
      if (existing.kind == SourceKind.m3u) {
        if (existing.isLocalFile) {
          _localPath = existing.url;
        } else {
          _url.text = existing.url ?? '';
        }
      } else {
        _host.text = existing.host ?? '';
        _user.text = existing.username ?? '';
        _pass.text = existing.password ?? '';
      }
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final c in [_name, _url, _epg, _agent, _host, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit playlist' : 'Add playlist'),
        bottom: _isEditing
            ? null
            : TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'M3U playlist'),
                  Tab(text: 'Xtream Codes'),
                ],
              ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: TabBarView(
              controller: _tabs,
              physics: _isEditing
                  ? const NeverScrollableScrollPhysics()
                  : null,
              children: [_buildM3u(), _buildXtream()],
            ),
          ),
        ),
      ),
    );
  }

  // --- M3U -----------------------------------------------------------------

  Widget _buildM3u() {
    final usingFile = _localPath != null;
    return Form(
      key: _m3uForm,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(
            controller: _name,
            label: 'Name',
            hint: 'My provider',
            icon: Icons.label_outline_rounded,
            validator: _required,
          ),
          const SizedBox(height: 14),
          if (usingFile)
            _FilePill(
              path: _localPath!,
              onClear: () => setState(() => _localPath = null),
            )
          else
            _field(
              controller: _url,
              label: 'Playlist URL',
              hint: 'http://example.com/playlist.m3u',
              icon: Icons.link_rounded,
              keyboardType: TextInputType.url,
              validator: _requiredUrl,
            ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(
                usingFile ? 'Choose a different file' : 'Use a local file instead',
              ),
            ),
          ),
          const SizedBox(height: 14),
          _field(
            controller: _epg,
            label: 'Guide URL (optional)',
            hint: 'XMLTV address, if your provider has one',
            icon: Icons.calendar_month_rounded,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 14),
          _agentField(),
          const SizedBox(height: 22),
          _message != null ? _banner() : const SizedBox.shrink(),
          if (_message != null) const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : _saveM3u,
            child: _busy
                ? const _ButtonSpinner()
                : Text(_isEditing ? 'Save changes' : 'Add playlist'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Playlists',
          extensions: ['m3u', 'm3u8'],
          mimeTypes: ['audio/x-mpegurl', 'application/vnd.apple.mpegurl'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    setState(() {
      _localPath = file.path;
      if (_name.text.trim().isEmpty) {
        _name.text = file.name.replaceAll(RegExp(r'\.m3u8?$'), '');
      }
    });
  }

  Future<void> _saveM3u() async {
    if (_localPath == null && !(_m3uForm.currentState?.validate() ?? false)) {
      return;
    }
    if (_localPath != null && _name.text.trim().isEmpty) {
      setState(() {
        _message = 'Give the playlist a name.';
        _messageIsError = true;
      });
      return;
    }

    final source = PlaylistSource(
      id: widget.existing?.id ?? _newId(),
      name: _name.text.trim(),
      kind: SourceKind.m3u,
      url: _localPath ?? _url.text.trim(),
      isLocalFile: _localPath != null,
      epgUrl: _blank(_epg.text),
      userAgent: _blank(_agent.text),
    );
    await _commit(source);
  }

  // --- Xtream --------------------------------------------------------------

  Widget _buildXtream() {
    return Form(
      key: _xtreamForm,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(
            controller: _name,
            label: 'Name',
            hint: 'My provider',
            icon: Icons.label_outline_rounded,
            validator: _required,
          ),
          const SizedBox(height: 14),
          _field(
            controller: _host,
            label: 'Server',
            hint: 'http://example.com:8080',
            icon: Icons.dns_rounded,
            keyboardType: TextInputType.url,
            validator: _required,
          ),
          const SizedBox(height: 14),
          _field(
            controller: _user,
            label: 'Username',
            icon: Icons.person_outline_rounded,
            validator: _required,
          ),
          const SizedBox(height: 14),
          _field(
            controller: _pass,
            label: 'Password',
            icon: Icons.lock_outline_rounded,
            obscure: !_showPassword,
            validator: _required,
            suffix: IconButton(
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 20,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _agentField(),
          const SizedBox(height: 22),
          if (_message != null) ...[_banner(), const SizedBox(height: 14)],
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _testXtream,
                  child: const Text('Test'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _busy ? null : _saveXtream,
                  child: _busy
                      ? const _ButtonSpinner()
                      : Text(_isEditing ? 'Save changes' : 'Add playlist'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _testXtream() async {
    if (!(_xtreamForm.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final state = context.read<AppState>();
    try {
      final account = await state.verifyXtream(
        host: _host.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        userAgent: _blank(_agent.text),
      );
      if (!mounted) return;
      final parts = <String>[
        'Connected as ${account.username}',
        if (account.expiresAt != null)
          'expires ${_date(account.expiresAt!)}'
        else
          'no expiry reported',
        if (account.maxConnections != null)
          '${account.activeConnections ?? 0}/${account.maxConnections} connections in use',
      ];
      setState(() {
        _message = parts.join(' · ');
        _messageIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.toString();
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveXtream() async {
    if (!(_xtreamForm.currentState?.validate() ?? false)) return;
    final source = PlaylistSource(
      id: widget.existing?.id ?? _newId(),
      name: _name.text.trim(),
      kind: SourceKind.xtream,
      host: _host.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      epgUrl: _blank(_epg.text),
      userAgent: _blank(_agent.text),
    );
    await _commit(source);
  }

  // --- Shared --------------------------------------------------------------

  Future<void> _commit(PlaylistSource source) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);
    if (_isEditing) {
      await state.updateSource(source);
    } else {
      await state.addSource(source);
    }
    if (!mounted) return;
    // The browse screen surfaces any load failure; the form's job is done.
    navigator.pop();
  }

  Widget _agentField() => _field(
    controller: _agent,
    label: 'User-Agent (optional)',
    hint: Settings.defaultUserAgent,
    icon: Icons.badge_outlined,
  );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: suffix,
      ),
    );
  }

  Widget _banner() {
    final scheme = Theme.of(context).colorScheme;
    final color = _messageIsError ? scheme.error : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _messageIsError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _message!,
              style: TextStyle(fontSize: 13, height: 1.4, color: color),
            ),
          ),
        ],
      ),
    );
  }

  static String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  static String? _requiredUrl(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Required';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Enter a full address starting with http:// or https://';
    }
    return null;
  }

  static String? _blank(String value) {
    final v = value.trim();
    return v.isEmpty ? null : v;
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _FilePill extends StatelessWidget {
  const _FilePill({required this.path, required this.onClear});

  final String path;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 14, right: 4),
      height: 56,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          IconButton(
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Remove file',
          ),
        ],
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.black),
    );
  }
}
