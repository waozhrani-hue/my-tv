import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Wordmark used on the welcome screen and in the browse header.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40, this.showLabel = true});

  final double size;

  /// The wordmark is dropped where horizontal space is tight, such as the
  /// phone header.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primary, scheme.primary.withValues(alpha: 0.55)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          child: Icon(
            Icons.live_tv_rounded,
            size: size * 0.6,
            color: AppTheme.background,
          ),
        ),
        if (showLabel) ...[
          SizedBox(width: size * 0.32),
          Text(
            'My TV',
            style: TextStyle(
              fontSize: size * 0.56,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
        ],
      ],
    );
  }
}

/// A channel or poster image with a readable fallback, since a good share of
/// IPTV logo URLs are dead.
///
/// A null [size] makes the widget fill its parent, which is what the movie
/// poster grid needs.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({
    super.key,
    required this.url,
    required this.name,
    this.size = 48,
    this.radius = 10,
    this.fit = BoxFit.contain,
  });

  final String? url;
  final String name;
  final double? size;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final fallback = _Initials(name: name, size: size, radius: radius);
    final address = url?.trim();
    if (address == null || address.isEmpty || !address.startsWith('http')) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: address,
        width: size,
        height: size,
        fit: fit,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size, required this.radius});

  final String name;
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final letters = name
        .split(RegExp(r'[\s|_\-/]+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w.substring(0, 1).toUpperCase())
        .join();
    // Deterministic hue so the same channel always gets the same tint.
    final hue = (name.hashCode.abs() % 360).toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.35, 0.32).toColor();

    return LayoutBuilder(
      builder: (context, constraints) {
        // With no fixed size the widget is laid out by its parent, so derive
        // the type scale from whatever box it actually gets.
        final box = size ??
            [
              constraints.maxWidth,
              constraints.maxHeight,
            ].where((v) => v.isFinite).fold<double>(48, (a, b) => a < b ? a : b);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(radius),
          ),
          alignment: Alignment.center,
          child: Text(
            letters.isEmpty ? '?' : letters,
            style: TextStyle(
              fontSize: (box * 0.34).clamp(11.0, 44.0),
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.92),
            ),
          ),
        );
      },
    );
  }
}

class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.live,
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Shared presentation for "nothing here" and "it went wrong".
class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: (isError ? scheme.error : scheme.primary)
                      .withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 32,
                  color: isError ? scheme.error : scheme.primary,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: Colors.white.withValues(alpha: 0.62),
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 22), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Centred spinner with a caption, used while a playlist loads.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(
              label!,
              style: TextStyle(
                fontSize: 13.5,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
