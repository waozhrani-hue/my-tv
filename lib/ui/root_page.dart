import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../state/app_state.dart';
import 'add_source_page.dart';
import 'browse_page.dart';
import 'pair_page.dart';
import 'widgets/common.dart';

/// Chooses between first-run onboarding and the channel browser.
class RootPage extends StatelessWidget {
  const RootPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.booted) {
      return const Scaffold(body: LoadingView());
    }
    if (!state.hasSources) return const WelcomePage();
    return const BrowsePage();
  }
}

/// Shown until the first playlist is added.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              children: [
                const AppLogo(size: 52),
                const SizedBox(height: 10),
                Text(
                  AppInfo.edition,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Add your playlist to get started',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(
                  'My TV plays the channels from a playlist you supply. '
                  'Nothing is bundled and nothing leaves this device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 32),
                _Option(
                  icon: Icons.link_rounded,
                  title: 'M3U playlist',
                  subtitle: 'A playlist link, or an .m3u file on this device',
                  onTap: () => _open(context, SourceFormTab.m3u),
                ),
                const SizedBox(height: 12),
                _Option(
                  icon: Icons.dns_rounded,
                  title: 'Xtream Codes account',
                  subtitle: 'Server address with a username and password',
                  onTap: () => _open(context, SourceFormTab.xtream),
                ),
                const SizedBox(height: 12),
                _Option(
                  icon: Icons.phone_iphone_rounded,
                  title: 'Type it on your phone',
                  subtitle:
                      'Scan a code and fill it in with a proper keyboard',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PairPage()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, SourceFormTab tab) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AddSourcePage(initialTab: tab)),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: scheme.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
