// The time of a splat scene (lib/desktop/ai/splat/splat_time.dart, lot SP6): the times kept for 150 images scaled to
// the job, the exhaustive matching by its pairs, the time left of a step by its pace, the training by the pace of its
// last 1 000 steps, which on the log of M1 (the room at 1 024 pixels, 20 000 steps, 366 s) tells the time left at mid
// training within a few percent, and the times a job measured taken back to 150 images before they are kept.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_time.dart';

Map<ImmersiveStage, Duration> _reference(String kind) => {
  for (final MapEntry(:key, :value) in aiDefaultTimings[kind]!.entries)
    ImmersiveStage.values.byName(key): Duration(milliseconds: value),
};

SplatTimeModel _photos(int images) => SplatTimeModel(
  reference: _reference('splatScene'),
  stages: ImmersiveStage.splatOf(video: false),
  images: images,
  video: false,
);

void main() {
  test('150 photos take the times kept: some 13 minutes by default', () {
    final model = _photos(150);
    expect(model.expected(ImmersiveStage.matching), const Duration(seconds: 195));
    expect(model.expected(ImmersiveStage.training), const Duration(seconds: 450));
    expect(model.total, const Duration(milliseconds: 5000 + 45000 + 15000 + 195000 + 50000 + 450000 + 10000 + 1000));
    expect(model.total.inMinutes, 12);
  });

  test('fewer photos: the points and the mapping by their images, the exhaustive matching by its pairs', () {
    final model = _photos(75);
    expect(model.expected(ImmersiveStage.features), const Duration(milliseconds: 7500));
    expect(model.expected(ImmersiveStage.mapping), const Duration(seconds: 25));
    // 75 x 74 / (150 x 149) of 195 s
    expect(model.expected(ImmersiveStage.matching).inMilliseconds, closeTo(195000 * 75 * 74 / (150 * 149), 1));
    expect(model.expected(ImmersiveStage.training), const Duration(seconds: 450), reason: 'one image a step');
    expect(model.expected(ImmersiveStage.frames), Duration.zero, reason: 'a job of photos takes no frames');
  });

  test('a video: its matching by its frames, sequential', () {
    final model = SplatTimeModel(
      reference: _reference('splatSceneVideo'),
      stages: ImmersiveStage.splatOf(video: true),
      images: 250,
      video: true,
    );
    expect(model.expected(ImmersiveStage.matching).inMilliseconds, closeTo(81000 * 250 / 150, 1));
    expect(model.expected(ImmersiveStage.photos), Duration.zero);
  });

  test('the images known once prepared change what is expected of the steps after', () {
    final model = _photos(200);
    final before = model.after(ImmersiveStage.photos);
    model.images = 100;
    expect(model.after(ImmersiveStage.photos), lessThan(before));
  });

  test('a step with counts: what was expected first, then its pace, blended by what is done', () {
    final model = _photos(150);
    // 3 of 150 points found after 2 s: too early for a pace
    expect(
      model.leftOf(ImmersiveStage.features, inStage: const Duration(seconds: 2), done: 3, total: 150),
      const Duration(seconds: 13),
    );
    // Half the points after 30 s, twice as slow as expected: half the pace, half the expectation
    final half = model.leftOf(ImmersiveStage.features, inStage: const Duration(seconds: 30), done: 75, total: 150);
    expect(half, const Duration(seconds: 15));
    // All but one done: nearly nothing left
    final end = model.leftOf(ImmersiveStage.features, inStage: const Duration(seconds: 60), done: 149, total: 150);
    expect(end.inMilliseconds, lessThan(500));
    // A step without counts, over its time: nothing left of it, the steps after it remain
    expect(model.leftOf(ImmersiveStage.splatCopy, inStage: const Duration(minutes: 1)), Duration.zero);
    expect(
      model.left(ImmersiveStage.splatCopy, inStage: const Duration(minutes: 1)),
      model.expected(ImmersiveStage.writing),
    );
  });

  test('the thousandths: each step weighs what it is expected to take, never going back', () {
    final model = _photos(150);
    var last = -1;
    for (final stage in model.stages) {
      for (final fraction in [0.0, 0.5, 1.0]) {
        final now = model.perMille(stage, fraction);
        expect(now, greaterThanOrEqualTo(last), reason: '${stage.name} $fraction');
        last = now;
      }
    }
    expect(model.perMille(ImmersiveStage.writing, 1), 1000);
    expect(model.perMille(ImmersiveStage.training, 0), closeTo(1000 * (5 + 45 + 15 + 195 + 50) / 771, 1));
  });

  test('the times of a job of 75 photos kept as those of 150', () {
    final model = _photos(75);
    expect(model.normalized(ImmersiveStage.features, const Duration(seconds: 8)), const Duration(seconds: 16));
    expect(
      model.normalized(ImmersiveStage.matching, const Duration(seconds: 48)).inMilliseconds,
      closeTo(48000 * (150 * 149) / (75 * 74), 1),
    );
    expect(model.normalized(ImmersiveStage.training, const Duration(minutes: 7)), const Duration(minutes: 7));
  });

  group('the pace of a training', () {
    test('the last 1 000 steps tell the time left', () {
      final pace = SplatTrainingPace();
      expect(pace.left(20000), isNull);
      // 10 ms a step for the first 2 000, then 20 ms
      for (var step = 200; step <= 2000; step += 200) {
        pace.add(step, Duration(milliseconds: step * 10));
      }
      for (var step = 2200; step <= 4000; step += 200) {
        pace.add(step, Duration(milliseconds: 20000 + (step - 2000) * 20));
      }
      expect(pace.left(20000), const Duration(milliseconds: 16000 * 20));
      // A count that goes back changes nothing
      pace.add(3000, const Duration(seconds: 1));
      expect(pace.left(20000), const Duration(milliseconds: 16000 * 20));
    });

    test('the log of M1: at mid training, the time left within 20 % of what it took', () {
      // [2026-11-01T14:17:12Z INFO  brush_cli] Refine iter 201, 31583 splats.
      final line = RegExp(r'^\[(\S+)Z INFO  brush_cli\] Refine iter (\d+), \d+ splats\.');
      final lines = File('test/fixtures/splat/logs/m1-room1024.out').readAsLinesSync();
      final start = DateTime.parse('${RegExp(r'^\[(\S+)Z').firstMatch(lines.first)!.group(1)!}Z');
      final doneLine = lines.lastWhere((text) => text.contains('Done training!'));
      final end = DateTime.parse('${RegExp(r'^\[(\S+)Z').firstMatch(doneLine)!.group(1)!}Z');
      final pace = SplatTrainingPace();
      Duration? told;
      DateTime? mid;
      for (final text in lines) {
        final match = line.firstMatch(text);
        if (match == null) {
          continue;
        }
        final at = DateTime.parse('${match.group(1)}Z');
        final step = int.parse(match.group(2)!);
        pace.add(step, at.difference(start));
        if (step >= 10000 && told == null) {
          told = pace.left(20000);
          mid = at;
        }
      }
      final took = end.difference(mid!);
      final error = (told!.inMilliseconds - took.inMilliseconds).abs() / took.inMilliseconds;
      expect(error, lessThan(0.2), reason: 'told $told, took $took');
    });
  });
}
