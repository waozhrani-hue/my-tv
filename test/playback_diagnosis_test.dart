import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/models.dart';
import 'package:my_tv/data/playback_diagnosis.dart';

/// These come from a real lockout: every device on the account showed "this
/// stream will not play" at once, the panel reported the subscription active
/// and 1 of 1 connections in use, and every stream URL answered HTTP 460.
/// Nothing in the player could have said why.
void main() {
  XtreamAccount account({
    String status = 'Active',
    int? max,
    int? active,
    DateTime? expires,
  }) => XtreamAccount(
    username: 'u',
    status: status,
    maxConnections: max,
    activeConnections: active,
    expiresAt: expires,
  );

  test('an account at its connection limit says so, with the figures', () {
    final message = PlaybackDiagnosis.forAccount(
      account(max: 1, active: 1),
    );
    expect(message, isNotNull);
    expect(message, contains('1 of 1'));
    expect(message, contains('one connection'));
    // The part that matters: the other devices are the cause.
    expect(message, contains('background'));
  });

  test('two of two reads naturally', () {
    final message = PlaybackDiagnosis.forAccount(account(max: 2, active: 2));
    expect(message, contains('2 of 2'));
    expect(message, contains('2 connections'));
  });

  test('a spare connection is not an explanation', () {
    expect(PlaybackDiagnosis.forAccount(account(max: 2, active: 1)), isNull);
  });

  test('an expired subscription is named outright', () {
    final message = PlaybackDiagnosis.forAccount(account(status: 'Expired'));
    expect(message, contains('expired'));
  });

  test('a banned account is distinguished from an expired one', () {
    final message = PlaybackDiagnosis.forAccount(account(status: 'Banned'));
    expect(message, contains('disabled'));
  });

  test('a date in the past is caught even when the status says active', () {
    final message = PlaybackDiagnosis.forAccount(
      account(expires: DateTime(2024, 3, 7)),
      now: DateTime(2026, 11, 16),
    );
    expect(message, contains('2024-03-07'));
  });

  test('a healthy account returns nothing, so the failure is retried', () {
    final message = PlaybackDiagnosis.forAccount(
      account(max: 2, active: 0, expires: DateTime(2027, 6, 1)),
      now: DateTime(2026, 11, 16),
    );
    expect(message, isNull);
  });

  test('an account the panel reports no limits for is not blamed', () {
    expect(PlaybackDiagnosis.forAccount(account()), isNull);
  });

  group('the setting that frees the connection', () {
    test('is on by default, because one connection is the common case', () {
      expect(const Settings().releaseOnBackground, isTrue);
      expect(Settings.fromJson(const {}).releaseOnBackground, isTrue);
    });

    test('survives a round trip when turned off', () {
      final stored = const Settings(releaseOnBackground: false).toJson();
      expect(Settings.fromJson(stored).releaseOnBackground, isFalse);
    });
  });
}
