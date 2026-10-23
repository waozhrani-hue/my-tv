import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/models.dart';

void main() {
  group('WatchProgress.isResumable', () {
    WatchProgress at(int seconds, {int of = 3600}) => WatchProgress(
      position: Duration(seconds: seconds),
      duration: Duration(seconds: of),
    );

    test('a position in the middle resumes', () {
      expect(at(1800).isResumable, isTrue);
    });

    test('the first few seconds are not worth resuming', () {
      expect(at(5).isResumable, isFalse);
      expect(at(19).isResumable, isFalse);
      expect(at(20).isResumable, isTrue);
    });

    test('the closing minute counts as finished', () {
      // 45s of tail margin, so 3555 is the last resumable second.
      expect(at(3554).isResumable, isTrue);
      expect(at(3580).isResumable, isFalse);
      expect(at(3600).isResumable, isFalse);
    });

    test('an unknown duration is never resumable', () {
      expect(at(600, of: 0).isResumable, isFalse);
    });
  });

  group('WatchProgress.fraction', () {
    test('is the share of the running time watched', () {
      final p = WatchProgress(
        position: const Duration(minutes: 30),
        duration: const Duration(hours: 2),
      );
      expect(p.fraction, closeTo(0.25, 0.0001));
    });

    test('is zero when the duration is unknown', () {
      const p = WatchProgress(
        position: Duration(minutes: 5),
        duration: Duration.zero,
      );
      expect(p.fraction, 0);
    });

    test('never exceeds one', () {
      const p = WatchProgress(
        position: Duration(hours: 3),
        duration: Duration(hours: 2),
      );
      expect(p.fraction, 1.0);
    });
  });

  test('WatchProgress survives a JSON round trip', () {
    const original = WatchProgress(
      position: Duration(minutes: 42, seconds: 17),
      duration: Duration(hours: 1, minutes: 55),
    );
    final restored = WatchProgress.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.position, const Duration(minutes: 42, seconds: 17));
    expect(restored.duration, const Duration(hours: 1, minutes: 55));
  });

  group('ViewMode', () {
    test('other flips between the two layouts', () {
      expect(ViewMode.list.other, ViewMode.grid);
      expect(ViewMode.grid.other, ViewMode.list);
    });

    test('settings pick a layout per kind', () {
      const s = Settings(liveView: ViewMode.grid, movieView: ViewMode.list);
      expect(s.viewFor(MediaKind.live), ViewMode.grid);
      expect(s.viewFor(MediaKind.movie), ViewMode.list);
    });

    test('defaults are a list of channels and a grid of films', () {
      const s = Settings();
      expect(s.viewFor(MediaKind.live), ViewMode.list);
      expect(s.viewFor(MediaKind.movie), ViewMode.grid);
    });
  });

  group('Settings with the new fields', () {
    test('survives a JSON round trip', () {
      const original = Settings(
        liveView: ViewMode.grid,
        movieView: ViewMode.list,
        resumePlayback: false,
      );
      final restored = Settings.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.liveView, ViewMode.grid);
      expect(restored.movieView, ViewMode.list);
      expect(restored.resumePlayback, isFalse);
    });

    test('settings saved before these fields existed still load', () {
      final restored = Settings.fromJson(const {
        'liveContainer': 'hls',
        'userAgent': 'Old/1.0',
      });
      expect(restored.liveContainer, LiveContainer.hls);
      expect(restored.liveView, ViewMode.list);
      expect(restored.movieView, ViewMode.grid);
      expect(restored.resumePlayback, isTrue);
      expect(restored.skipSeconds, 10);
    });
  });

  group('skip step', () {
    test('defaults to ten seconds', () {
      expect(const Settings().skipSeconds, 10);
      expect(const Settings().skip, const Duration(seconds: 10));
    });

    test('survives a JSON round trip', () {
      final restored = Settings.fromJson(
        jsonDecode(jsonEncode(const Settings(skipSeconds: 30).toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.skipSeconds, 30);
      expect(restored.skip, const Duration(seconds: 30));
    });

    test('every offered choice is a positive number of seconds', () {
      expect(Settings.skipChoices, isNotEmpty);
      expect(Settings.skipChoices.every((s) => s > 0), isTrue);
      // The default must be selectable, or the dropdown throws.
      expect(Settings.skipChoices, contains(const Settings().skipSeconds));
    });
  });
}
