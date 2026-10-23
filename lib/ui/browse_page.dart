import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'add_source_page.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets/common.dart';

enum BrowseSection {
  live('Live TV', Icons.live_tv_rounded),
  movies('Movies', Icons.movie_outlined),
  favorites('Favourites', Icons.star_rounded),
  recent('Recent', Icons.history_rounded);

  const BrowseSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The channel browser: playlist picker, section rail, category filter,
/// search, and the item list itself.
class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  static const _wideBreakpoint = 900.0;

  final _search = TextEditingController();
  BrowseSection _section = BrowseSection.live;
  String? _group;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final sections = _visibleSections(state);
    if (!sections.contains(_section)) _section = sections.first;

    return Scaffold(
      body: SafeArea(
        child: isWide
            ? _buildWide(state, sections)
            : _buildNarrow(state, sections),
      ),
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: sections.indexOf(_section),
              onDestinationSelected: (i) => _selectSection(sections[i]),
              destinations: [
                for (final s in sections)
                  NavigationDestination(
                    icon: Icon(s.icon),
                    label: s.label,
                  ),
              ],
            ),
    );
  }

  List<BrowseSection> _visibleSections(AppState state) => [
    BrowseSection.live,
    if (state.catalog.movies.isNotEmpty) BrowseSection.movies,
    BrowseSection.favorites,
    BrowseSection.recent,
  ];

  void _selectSection(BrowseSection section) {
    setState(() {
      _section = section;
      _group = null;
    });
  }

  // --- Layouts -------------------------------------------------------------

  Widget _buildWide(AppState state, List<BrowseSection> sections) {
    final groups = _groupsForSection(state);
    return Row(
      children: [
        NavigationRail(
          selectedIndex: sections.indexOf(_section),
          onDestinationSelected: (i) => _selectSection(sections[i]),
          labelType: NavigationRailLabelType.all,
          leading: const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: AppLogo(size: 34),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
            ),
          ),
          destinations: [
            for (final s in sections)
              NavigationRailDestination(
                icon: Icon(s.icon),
                label: Text(s.label),
              ),
          ],
        ),
        const VerticalDivider(width: 1),
        if (groups.isNotEmpty) ...[
          SizedBox(
            width: 232,
            child: _GroupList(
              groups: groups,
              selected: _group,
              onSelected: (g) => setState(() => _group = g),
            ),
          ),
          const VerticalDivider(width: 1),
        ],
        Expanded(
          child: Column(
            children: [
              _header(state, compact: false),
              const Divider(height: 1),
              Expanded(child: _content(state)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNarrow(AppState state, List<BrowseSection> sections) {
    final groups = _groupsForSection(state);
    return Column(
      children: [
        _header(state, compact: true),
        if (groups.isNotEmpty)
          _GroupChips(
            groups: groups,
            selected: _group,
            onSelected: (g) => setState(() => _group = g),
          ),
        const Divider(height: 1),
        Expanded(child: _content(state)),
      ],
    );
  }

  // --- Header --------------------------------------------------------------

  Widget _header(AppState state, {required bool compact}) {
    final count = _items(state).length;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 12, compact ? 8 : 16, 12),
      child: Row(
        children: [
          if (compact) ...[
            // Mark only: the wordmark costs about 60px that a phone header
            // cannot spare, and the app name is already in the task switcher.
            const AppLogo(size: 28, showLabel: false),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact)
                  Text(
                    _group ?? _section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                if (!compact && state.status == LoadStatus.ready)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '$count ${count == 1 ? 'item' : 'items'}'
                      '${state.current != null ? ' · ${state.current!.name}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Flexible on a phone: a fixed width plus the action buttons was
          // wider than the screen, and Row silently clips what overflows -
          // which hid the menu holding Settings entirely.
          _Flexible(
            flex: compact,
            width: 280,
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 17),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (state.availableUpdate case final update?)
            IconButton(
              tooltip: state.isDownloadingUpdate
                  ? 'Downloading ${update.version} — '
                        '${(state.downloadProgress * 100).round()}%'
                  : 'Version ${update.version} is available',
              onPressed: _openSettings,
              icon: state.isDownloadingUpdate
                  // Shows the transfer is still running after the user has
                  // left the settings screen.
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        value: state.downloadProgress,
                        strokeWidth: 2.4,
                      ),
                    )
                  : Badge(
                      smallSize: 8,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: const Icon(Icons.system_update_rounded),
                    ),
            ),
          // On a phone these two move into the menu, so the row always fits.
          if (!compact) ...[
            IconButton(
              tooltip: _viewMode(state) == ViewMode.grid
                  ? 'Show as a list'
                  : 'Show as a grid',
              onPressed: () => _toggleViewMode(state),
              icon: Icon(
                _viewMode(state) == ViewMode.grid
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Reload playlist',
              onPressed: state.status == LoadStatus.loading
                  ? null
                  : state.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          _SourceMenu(
            onSettings: _openSettings,
            onRefresh: compact ? state.refresh : null,
            onToggleView: compact ? () => _toggleViewMode(state) : null,
            viewMode: _viewMode(state),
          ),
        ],
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  // --- Content -------------------------------------------------------------

  List<String> _groupsForSection(AppState state) {
    if (state.status != LoadStatus.ready) return const [];
    return switch (_section) {
      BrowseSection.live => state.catalog.groupsOf(MediaKind.live),
      BrowseSection.movies => state.catalog.groupsOf(MediaKind.movie),
      BrowseSection.favorites || BrowseSection.recent => const [],
    };
  }

  List<MediaItem> _items(AppState state) {
    final needle = _search.text.trim().toLowerCase();
    bool matches(MediaItem i) =>
        needle.isEmpty || i.name.toLowerCase().contains(needle);

    return switch (_section) {
      BrowseSection.live => state.query(
        kind: MediaKind.live,
        group: _group,
        search: _search.text,
      ),
      BrowseSection.movies => state.query(
        kind: MediaKind.movie,
        group: _group,
        search: _search.text,
      ),
      BrowseSection.favorites => state.favoriteItems.where(matches).toList(),
      BrowseSection.recent => state.recentItems.where(matches).toList(),
    };
  }

  Widget _content(AppState state) {
    switch (state.status) {
      case LoadStatus.loading:
        return const LoadingView(label: 'Loading playlist…');
      case LoadStatus.error:
        return StatusView(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load this playlist',
          message: state.error,
          isError: true,
          action: Wrap(
            spacing: 10,
            children: [
              FilledButton(onPressed: state.refresh, child: const Text('Try again')),
              OutlinedButton(
                onPressed: () {
                  final current = state.current;
                  if (current == null) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AddSourcePage(existing: current),
                    ),
                  );
                },
                child: const Text('Edit playlist'),
              ),
            ],
          ),
        );
      case LoadStatus.idle:
        return const LoadingView();
      case LoadStatus.ready:
        break;
    }

    final items = _items(state);
    if (items.isEmpty) return _emptyFor();

    if (_viewMode(state) == ViewMode.grid) {
      return _ItemGrid(
        items: items,
        onPlay: _play,
        // Films have poster art worth showing tall; channel logos do not.
        poster: _section == BrowseSection.movies,
      );
    }
    return _ItemList(items: items, onPlay: _play);
  }

  /// Films and channels keep separate layout preferences. Favourites and
  /// history are mixed, so they follow the channel setting.
  ViewMode _viewMode(AppState state) => _section == BrowseSection.movies
      ? state.settings.movieView
      : state.settings.liveView;

  void _toggleViewMode(AppState state) {
    final settings = state.settings;
    final next = _viewMode(state).other;
    state.updateSettings(
      _section == BrowseSection.movies
          ? settings.copyWith(movieView: next)
          : settings.copyWith(liveView: next),
    );
  }

  Widget _emptyFor() {
    if (_search.text.trim().isNotEmpty) {
      return StatusView(
        icon: Icons.search_off_rounded,
        title: 'Nothing matches "${_search.text.trim()}"',
        message: 'Try a shorter search, or clear the category filter.',
      );
    }
    return switch (_section) {
      BrowseSection.favorites => const StatusView(
        icon: Icons.star_outline_rounded,
        title: 'No favourites yet',
        message: 'Tap the star on any channel to keep it here.',
      ),
      BrowseSection.recent => const StatusView(
        icon: Icons.history_rounded,
        title: 'Nothing watched yet',
        message: 'Channels you play will show up here.',
      ),
      _ => const StatusView(
        icon: Icons.inbox_rounded,
        title: 'Nothing in this category',
      ),
    };
  }

  void _play(MediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(item: item),
        fullscreenDialog: true,
      ),
    );
  }
}

// --- Playlist switcher -------------------------------------------------------

/// Lets a child be a fixed width on a wide window and flexible on a phone.
class _Flexible extends StatelessWidget {
  const _Flexible({
    required this.flex,
    required this.width,
    required this.child,
  });

  final bool flex;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      flex ? Expanded(child: child) : SizedBox(width: width, child: child);
}

/// Playlist switcher, and on a phone the home for the actions that do not fit
/// in the header.
class _SourceMenu extends StatelessWidget {
  const _SourceMenu({
    required this.onSettings,
    required this.viewMode,
    this.onRefresh,
    this.onToggleView,
  });

  final VoidCallback onSettings;
  final ViewMode viewMode;

  /// Non-null only in the compact layout, where these have no header button.
  final VoidCallback? onRefresh;
  final VoidCallback? onToggleView;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) {
        switch (value) {
          case '#add':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddSourcePage()),
            );
          case '#settings':
            onSettings();
          case '#refresh':
            onRefresh?.call();
          case '#view':
            onToggleView?.call();
          default:
            state.selectSource(value);
        }
      },
      itemBuilder: (context) => [
        if (onToggleView != null)
          PopupMenuItem<String>(
            value: '#view',
            child: Row(
              children: [
                Icon(
                  viewMode == ViewMode.grid
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(
                  viewMode == ViewMode.grid
                      ? 'Show as a list'
                      : 'Show as a grid',
                ),
              ],
            ),
          ),
        if (onRefresh != null)
          PopupMenuItem<String>(
            value: '#refresh',
            enabled: state.status != LoadStatus.loading,
            child: const Row(
              children: [
                Icon(Icons.refresh_rounded, size: 18),
                SizedBox(width: 10),
                Text('Reload playlist'),
              ],
            ),
          ),
        if (onToggleView != null || onRefresh != null) const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          height: 34,
          child: Text(
            'PLAYLISTS',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        for (final source in state.sources)
          PopupMenuItem<String>(
            value: source.id,
            child: Row(
              children: [
                Icon(
                  source.kind == SourceKind.xtream
                      ? Icons.dns_rounded
                      : Icons.link_rounded,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(source.name, overflow: TextOverflow.ellipsis),
                ),
                if (source.id == state.current?.id)
                  Icon(
                    Icons.check_rounded,
                    size: 17,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '#add',
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 18),
              SizedBox(width: 10),
              Text('Add playlist'),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: '#settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 18),
              SizedBox(width: 10),
              Text('Settings'),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Category filters --------------------------------------------------------

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  final List<String> groups;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: groups.length + 1,
      itemBuilder: (context, index) {
        final group = index == 0 ? null : groups[index - 1];
        final isSelected = group == selected;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Material(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: () => onSelected(group),
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Text(
                  group ?? 'All categories',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected
                        ? scheme.primary
                        : Colors.white.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GroupChips extends StatelessWidget {
  const _GroupChips({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  final List<String> groups;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: groups.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final group = index == 0 ? null : groups[index - 1];
          return Center(
            child: ChoiceChip(
              label: Text(group ?? 'All'),
              selected: group == selected,
              onSelected: (_) => onSelected(group),
            ),
          );
        },
      ),
    );
  }
}

// --- Item lists --------------------------------------------------------------

class _ItemList extends StatelessWidget {
  const _ItemList({required this.items, required this.onPlay});

  final List<MediaItem> items;
  final ValueChanged<MediaItem> onPlay;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final item = items[index];
        final isFavorite = state.isFavorite(item.id);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              onTap: () => onPlay(item),
              borderRadius: BorderRadius.circular(11),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                  children: [
                    ChannelLogo(url: item.logo, name: item.name, size: 44),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if ((item.group ?? '').trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                item.group!.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (item.kind == MediaKind.live) ...[
                      const LiveBadge(),
                      const SizedBox(width: 6),
                    ],
                    IconButton(
                      onPressed: () => state.toggleFavorite(item),
                      tooltip: isFavorite
                          ? 'Remove from favourites'
                          : 'Add to favourites',
                      icon: Icon(
                        isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                        size: 21,
                        color: isFavorite
                            ? const Color(0xFFFFC53D)
                            : Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                    ),
                    if (state.progressFor(item.id) case final watched?)
                      Padding(
                        padding: const EdgeInsets.only(top: 7, left: 57, right: 8),
                        child: _ProgressStripe(fraction: watched.fraction),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tile layout for either section.
///
/// [poster] switches between tall film artwork, which is shot to fill, and
/// squarer channel tiles, where the logo is letterboxed because station logos
/// are wide and must not be cropped.
class _ItemGrid extends StatelessWidget {
  const _ItemGrid({
    required this.items,
    required this.onPlay,
    required this.poster,
  });

  final List<MediaItem> items;
  final ValueChanged<MediaItem> onPlay;
  final bool poster;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: poster ? 172 : 158,
        childAspectRatio: poster ? 0.58 : 0.84,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isFavorite = state.isFavorite(item.id);
        final watched = state.progressFor(item.id);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ColoredBox(
                      color: AppTheme.surfaceHigh,
                      child: Padding(
                        padding: EdgeInsets.all(poster ? 0 : 14),
                        child: ChannelLogo(
                          url: item.logo,
                          name: item.name,
                          size: null,
                          radius: poster ? 12 : 8,
                          fit: poster ? BoxFit.cover : BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  // Below the star on purpose: the last child in a Stack takes
                  // the hit first, and the star must stay tappable.
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onPlay(item),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  if (item.kind == MediaKind.live)
                    const Positioned(top: 6, left: 6, child: LiveBadge()),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      onPressed: () => state.toggleFavorite(item),
                      iconSize: 19,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                        minimumSize: const Size(30, 30),
                        padding: EdgeInsets.zero,
                      ),
                      icon: Icon(
                        isFavorite
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: isFavorite
                            ? const Color(0xFFFFC53D)
                            : Colors.white,
                      ),
                    ),
                  ),
                  if (watched != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: _ProgressStripe(fraction: watched.fraction),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, height: 1.3),
            ),
          ],
        );
      },
    );
  }
}

/// How far through a film the viewer got, drawn under its tile or row.
class _ProgressStripe extends StatelessWidget {
  const _ProgressStripe({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            ColoredBox(
              color: Colors.white.withValues(alpha: 0.22),
              child: const SizedBox.expand(),
            ),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.02, 1.0),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.primary,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
