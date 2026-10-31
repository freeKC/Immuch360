import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';

// The film rule and the watched rule of FreeKC's request of 31 October 2026: a long video resumes where it was left, a
// shorter one always starts from the beginning; a film stopped in its last two minutes is watched and starts from 0
void main() {
  const minute = Duration(minutes: 1);
  final now = DateTime.utc(2026, 10, 31, 9);
  const film = Duration(minutes: 98);

  group('WatchRule', () {
    test('a video of at least the threshold is a film, by default 10 minutes', () {
      const rule = WatchRule();

      expect(rule.isFilm(minute * 10), isTrue);
      expect(rule.isFilm(film), isTrue);
      expect(rule.isFilm(minute * 10 - const Duration(milliseconds: 1)), isFalse);
      expect(rule.isFilm(const Duration(seconds: 40)), isFalse);
    });

    test('nothing is a film without a duration', () {
      const rule = WatchRule(minMinutes: 0);

      expect(rule.isFilm(null), isFalse);
      expect(rule.isFilm(Duration.zero), isFalse);
    });

    test('a threshold of 0 makes every video whose duration is known a film', () {
      const rule = WatchRule(minMinutes: 0);

      expect(rule.isFilm(const Duration(seconds: 3)), isTrue);
      expect(rule.isFilm(film), isTrue);
    });

    test('off, nothing is a film', () {
      const rule = WatchRule(enabled: false);

      expect(rule.isFilm(film), isFalse);
      expect(rule.minDurationMs, -1);
    });

    test('the immersive viewer of the Meta Quest gets the threshold in milliseconds', () {
      expect(const WatchRule().minDurationMs, 600000);
      expect(const WatchRule(minMinutes: 0).minDurationMs, 0);
      expect(const WatchRule(minMinutes: 25).minDurationMs, 1500000);
    });

    test('a negative threshold read from an old store counts as 0', () {
      expect(const WatchRule(minMinutes: -5).isFilm(const Duration(seconds: 3)), isTrue);
    });

    test('follows the settings of the viewer', () {
      const viewer = ViewerConfig(resumeVideos: true, resumeMinMinutes: 25);

      expect(WatchRule.of(viewer), const WatchRule(minMinutes: 25));
      expect(WatchRule.of(const ViewerConfig(resumeVideos: false)).enabled, isFalse);
    });

    test('on by default with 10 minutes, the lab rule', () {
      expect(WatchRule.of(const ViewerConfig()), const WatchRule());
      expect(const ViewerConfig().resumeVideos, isTrue);
      expect(const ViewerConfig().resumeMinMinutes, 10);
    });
  });

  group('the end tail and the start margin', () {
    test('two minutes and thirty seconds for every film at the default threshold', () {
      for (final duration in [minute * 10, minute * 25, film, const Duration(hours: 3)]) {
        expect(watchEndTail(duration), minute * 2, reason: '$duration');
        expect(watchStartMargin(duration), const Duration(seconds: 30), reason: '$duration');
      }
    });

    test('a fifth and a twentieth of a short clip, so that it is not watched as soon as it starts', () {
      const clip = Duration(seconds: 40);

      expect(watchEndTail(clip), const Duration(seconds: 8));
      expect(watchStartMargin(clip), const Duration(seconds: 2));
    });
  });

  group('recordWatch', () {
    WatchProgress? save(Duration position, {Duration duration = film, WatchProgress? previous}) =>
        recordWatch(key: 'asset:a', previous: previous, position: position, duration: duration, now: now);

    test('keeps a position in the middle', () {
      final row = save(minute * 42 + const Duration(seconds: 10));

      expect(row?.position, minute * 42 + const Duration(seconds: 10));
      expect(row?.duration, film);
      expect(row?.watched, isFalse);
      expect(row?.updatedAt, now);
      expect(row?.key, 'asset:a');
    });

    test('in the last two minutes, watched and back to 0, so that it starts from the beginning next time', () {
      final row = save(film - const Duration(seconds: 90));

      expect(row?.watched, isTrue);
      expect(row?.position, Duration.zero);
    });

    test('at the end, watched and back to 0', () {
      expect(save(film)?.watched, isTrue);
      expect(save(film + const Duration(seconds: 3))?.position, Duration.zero, reason: 'a position past the end');
    });

    test('right before the end tail, still in progress', () {
      final row = save(film - minute * 2 - const Duration(seconds: 1));

      expect(row?.watched, isFalse);
      expect(row?.position, film - minute * 2 - const Duration(seconds: 1));
    });

    test('under the start margin, nothing is kept: a film swiped past during its autoplay leaves no row', () {
      expect(save(const Duration(seconds: 12)), isNull);
      expect(save(Duration.zero), isNull);
      expect(save(-const Duration(seconds: 1)), isNull);
    });

    test('seeking back to 0 forgets the position of a film in progress', () {
      final before = save(minute * 42);

      expect(save(Duration.zero, previous: before), isNull);
    });

    test('a watched film seen again keeps its check, from 0 under the start margin and in progress past it', () {
      final watched = save(film);

      expect(save(const Duration(seconds: 5), previous: watched)?.watched, isTrue);
      expect(save(const Duration(seconds: 5), previous: watched)?.position, Duration.zero);
      final again = save(minute * 20, previous: watched);
      expect(again?.watched, isTrue);
      expect(again?.position, minute * 20);
    });

    test('nothing is known of a video without a duration: the row stays as it was', () {
      final before = save(minute * 42);

      expect(save(minute * 50, duration: Duration.zero, previous: before), before);
      expect(save(minute * 50, duration: Duration.zero), isNull);
    });

    test('keeps the fingerprint of the file given, else the one of the row', () {
      final first = recordWatch(
        key: 'share:s:/a.mkv',
        position: minute * 42,
        duration: film,
        now: now,
        fingerprint: 'fp:s:1:2',
      );
      final next = recordWatch(key: 'share:s:/a.mkv', previous: first, position: minute * 43, duration: film, now: now);

      expect(first?.fingerprint, 'fp:s:1:2');
      expect(next?.fingerprint, 'fp:s:1:2');
    });
  });

  group('resumeAt', () {
    const rule = WatchRule();
    final row = WatchProgress(key: 'asset:a', position: minute * 42, duration: film, watched: false, updatedAt: now);

    test('a film starts where it was left', () {
      expect(resumeAt(row, rule: rule), minute * 42);
      expect(resumeAt(row, rule: rule, duration: film + const Duration(seconds: 2)), minute * 42);
    });

    test('nothing without a row, and nothing for a watched film, which starts from 0', () {
      expect(resumeAt(null, rule: rule), Duration.zero);
      expect(resumeAt(row.copyWith(position: Duration.zero, watched: true), rule: rule), Duration.zero);
    });

    test('a shorter video always starts from the beginning', () {
      final clip = row.copyWith(position: const Duration(minutes: 4), duration: const Duration(minutes: 8));

      expect(resumeAt(clip, rule: rule), Duration.zero);
      expect(resumeAt(clip, rule: const WatchRule(minMinutes: 5)), const Duration(minutes: 4));
    });

    test('nothing with the setting off', () {
      expect(resumeAt(row, rule: const WatchRule(enabled: false)), Duration.zero);
    });

    test('from 0 when the duration known now differs by more than 2 s: the file was replaced', () {
      expect(resumeAt(row, rule: rule, duration: film + const Duration(seconds: 3)), Duration.zero);
      expect(resumeAt(row, rule: rule, duration: minute * 30), Duration.zero);
    });

    test('the duration known now decides whether it is a film', () {
      expect(resumeAt(row, rule: const WatchRule(minMinutes: 99), duration: film), Duration.zero);
    });
  });

  group('WatchProgress', () {
    test('the fraction watched, between 0 and 1', () {
      final row = WatchProgress(key: 'k', position: minute * 49, duration: film, watched: false, updatedAt: now);

      expect(row.fraction, closeTo(0.5, 0.001));
      expect(row.copyWith(position: film * 2).fraction, 1);
      expect(row.copyWith(duration: Duration.zero).fraction, 0);
    });

    test('equal rows are equal, so that a tile rebuilds only when its own row changes', () {
      final a = WatchProgress(key: 'k', position: minute, duration: film, watched: false, updatedAt: now);
      final b = WatchProgress(key: 'k', position: minute, duration: film, watched: false, updatedAt: now);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(watched: true), isNot(a));
    });
  });
}
