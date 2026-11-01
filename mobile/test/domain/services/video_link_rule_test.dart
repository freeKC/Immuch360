import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/video_link_rule.dart';

void main() {
  // The cases the Kotlin rule is checked against too (LinkStartRuleTest): both give the same answers
  final cases =
      jsonDecode(File('android/app/src/test/resources/video_link_rule_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String name) => (cases[name] as List).cast<Map<String, dynamic>>();
  double? ratio(Map<String, dynamic> c) => (c['ratio'] as num?)?.toDouble();

  test('the target of every shared case', () {
    for (final c in list('target')) {
      expect(linkTargetMs(ratio(c), rebuffering: c['rebuffering'] as bool), c['targetMs'], reason: '$c');
    }
  });

  test('whether it plays, in every shared case', () {
    for (final c in list('start')) {
      final started = linkShouldStart(
        c['bufferedMs'] as int,
        ratio(c),
        rebuffering: c['rebuffering'] as bool,
        minimumHeldMs: c['minimumHeldMs'] as int?,
      );
      expect(started, c['start'], reason: '$c');
    }
  });

  test('the wait that remains, in every shared case', () {
    for (final c in list('remaining')) {
      final remaining = linkRemainingWaitMs(
        c['bufferedMs'] as int,
        ratio(c),
        rebuffering: c['rebuffering'] as bool,
        minimumHeldMs: c['minimumHeldMs'] as int?,
      );
      expect(remaining, c['remainingMs'], reason: '$c');
    }
  });

  test('dead and slow, in every shared case', () {
    for (final c in list('dead')) {
      expect(
        linkIsDead(waiting: c['waiting'] as bool, sinceProgressMs: c['sinceProgressMs'] as int?),
        c['dead'],
        reason: '$c',
      );
    }
    for (final c in list('slow')) {
      expect(linkIsSlow(ratio(c), Duration(milliseconds: c['slowForMs'] as int)), c['slow'], reason: '$c');
    }
  });

  group('VideoLinkMeter', () {
    late DateTime now;
    late VideoLinkMeter meter;

    setUp(() {
      now = DateTime(2026, 10, 31, 20);
      meter = VideoLinkMeter(clock: () => now);
    });

    void receive(int bytesPerSecond, int ms) {
      for (var left = ms; left > 0; left -= 50) {
        now = now.add(const Duration(milliseconds: 50));
        meter.add(bytesPerSecond ~/ 20);
      }
    }

    test('no rate before a quarter of a megabyte or a second of loading', () {
      meter.start();
      receive(100000, 500);
      expect(meter.rate(), isNull);
      receive(100000, 600);
      expect(meter.rate(), closeTo(100000, 8000));
    });

    test('the rate is the one of the last four seconds', () {
      meter.start();
      receive(1000000, 4000);
      receive(250000, 4000);
      expect(meter.rate(), closeTo(250000, 20000));
    });

    test('a full buffer does not count as a slow link, a silent server does', () {
      meter.start();
      receive(1000000, 4000);
      meter.setWanted(false);
      now = now.add(const Duration(seconds: 10));
      expect(meter.rate(), closeTo(1000000, 60000));
      meter.setWanted(true);
      receive(1000000, 4000);
      now = now.add(const Duration(seconds: 3));
      expect(meter.rate(), closeTo(250000, 30000));
    });

    test('progress is every 16 KiB, counted from the first read', () {
      expect(meter.sinceProgress(), isNull);
      meter.start();
      now = now.add(const Duration(seconds: 5));
      expect(meter.sinceProgress(), const Duration(seconds: 5));
      meter.add(10000);
      now = now.add(const Duration(seconds: 1));
      expect(meter.sinceProgress(), const Duration(seconds: 6));
      meter.add(10000);
      expect(meter.sinceProgress(), Duration.zero);
    });

    // The clock of progress counts only the time bytes are asked (review of 1 November 2026: a film paused with its
    // buffer full, then a seek to a server that answers 2.5 s later, was said dead at once)

    test('a time with nothing asked, then an ask that waits 2 s for its first byte, is no dead link', () {
      meter.start();
      receive(1000000, 4000);
      meter.setWanted(false);
      now = now.add(const Duration(seconds: 40));
      meter.setWanted(true);
      now = now.add(const Duration(seconds: 2));
      expect(meter.sinceProgress(), const Duration(seconds: 2));
      expect(linkIsDead(waiting: true, sinceProgressMs: meter.sinceProgress()!.inMilliseconds), isFalse);
    });

    test('a read that ended, then a new one a while later that waits for its first byte, is no dead link', () {
      meter.start();
      receive(1000000, 2000);
      meter.end();
      now = now.add(const Duration(seconds: 40));
      meter.start();
      now = now.add(const Duration(seconds: 2));
      expect(meter.sinceProgress(), const Duration(seconds: 2));
    });

    test('reads that fail keep the clock: dead 30 s after the last byte', () {
      meter.start();
      receive(1000000, 2000);
      for (final retry in const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)]) {
        now = now.add(const Duration(seconds: 8));
        meter.end(failed: true);
        now = now.add(retry);
        meter.start();
      }
      expect(meter.sinceProgress(), const Duration(seconds: 31));
    });

    test('of two reads at once, the one that ends does not stop the clock of the other', () {
      meter
        ..start()
        ..start();
      receive(1000000, 2000);
      meter.end();
      // The other read waits for a share that no longer answers
      now = now.add(const Duration(seconds: 31));
      expect(meter.sinceProgress(), const Duration(seconds: 31));
    });

    test('a buffer topped up 1 MiB at a time measures the link, not what the film consumes', () {
      // A 4K film of 6 MB/s over a link of 25 MB/s, from a full buffer: 1 MiB asked each time the film consumed one,
      // at 5.1 MB/s in a calmer scene (it measured 0.7 of the film, "it will pause now and then", review of 1 November)
      meter.start();
      const chunk = 1 << 20;
      final end = now.add(const Duration(seconds: 20));
      while (now.isBefore(end)) {
        meter.setWanted(true);
        for (var left = chunk; left > 0;) {
          now = now.add(const Duration(milliseconds: 10));
          final bytes = math.min(left, 250000);
          meter.add(bytes);
          left -= bytes;
        }
        meter.setWanted(false);
        now = now.add(const Duration(microseconds: chunk * 1000000 ~/ 5100000));
      }
      final ratio = meter.rate()! / 6000000;
      expect(ratio, greaterThanOrEqualTo(VideoLinkRule.fastRatio));
    });
  });
}
