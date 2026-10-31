import 'dart:convert';
import 'dart:io';

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
  });
}
