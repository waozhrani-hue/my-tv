import 'models.dart';

/// Why a stream would not play, asked of the provider rather than guessed.
///
/// A player error says almost nothing useful on its own. The common cause is
/// invisible from the stream: most IPTV accounts allow one or two simultaneous
/// connections, and the panel is the only thing that knows they are all taken.
/// A one-connection account refuses every device at once, which looks exactly
/// like the app being broken everywhere.
class PlaybackDiagnosis {
  const PlaybackDiagnosis._();

  /// A message to show instead of the player's own, or null when the account
  /// is healthy and the failure was something else — a passing network dip,
  /// a channel that is off air — which is worth a retry.
  static String? forAccount(XtreamAccount account, {DateTime? now}) {
    final status = account.status.trim().toLowerCase();
    if (status == 'expired') {
      return 'This subscription has expired, so the provider is refusing the '
          'stream. Nothing is wrong with the app or the device.';
    }
    if (status == 'banned' || status == 'disabled') {
      return 'The provider has disabled this account, so it is refusing the '
          'stream. Nothing is wrong with the app or the device.';
    }

    final expires = account.expiresAt;
    if (expires != null && expires.isBefore(now ?? DateTime.now())) {
      return 'This subscription ran out on '
          '${expires.year}-${_two(expires.month)}-${_two(expires.day)}, so '
          'the provider is refusing the stream.';
    }

    final limit = account.maxConnections;
    final active = account.activeConnections;
    if (limit != null && limit > 0 && active != null && active >= limit) {
      final slots = limit == 1 ? 'one connection' : '$limit connections';
      return 'The provider is refusing the stream because the subscription is '
          'already at its limit: $active of $limit in use. It allows $slots at '
          'a time, counted across every device on the account.\n\n'
          'Close My TV completely on the other devices — on a phone or a TV '
          'box, leaving it open in the background keeps the connection — then '
          'try again. A connection left behind by an app that was killed can '
          'take a few minutes to clear by itself.';
    }

    return null;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
