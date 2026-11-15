// The status strip of the headset view (lib/desktop/video/xr/headset_strip.dart): its size and opaque background, its
// texts per state, the hint per controller profile, when it shows, and its images sent only when the text changed, at
// most 4 a second.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/xr/headset_strip.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import 'headset_test_support.dart';

void main() {
  testWidgets('1024 x 160 RGBA bytes, opaque, the text drawn on the dark background', (tester) async {
    final bytes = await tester.runAsync(
      () => renderHeadsetStrip(
        const HeadsetStripContent(title: 'Lisbon', state: 'Paused', time: '1:02:15 / 1:58:00', hint: 'Trigger'),
      ),
    );
    expect(bytes, hasLength(headsetStripWidth * headsetStripHeight * 4));
    for (var i = 3; i < bytes!.length; i += 4) {
      if (bytes[i] != 255) {
        fail('pixel ${i ~/ 4} is not opaque');
      }
    }
    expect(bytes.sublist(0, 4), [0x15, 0x17, 0x1C, 255], reason: 'the background at the top left corner');
    final lighter = [for (var i = 0; i < bytes.length; i += 4) bytes[i]].where((red) => red > 0x80).length;
    expect(lighter, greaterThan(100), reason: 'some text drawn');
  });

  group('the texts', () {
    late Translations t;

    testWidgets('per state, the hint per profile while paused, the third line', (tester) async {
      await tester.pumpWidget(
        localized(
          Builder(
            builder: (context) {
              t = context.t;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      const playing = HeadsetPlayback(
        position: Duration(hours: 1, minutes: 2, seconds: 15),
        duration: Duration(hours: 1, minutes: 58),
        status: HeadsetPlaybackStatus.playing,
      );
      var content = headsetStripContentOf(t, idle: false, title: 'Lisbon', playback: playing, hint: HeadsetHint.stick);
      expect(content.title, 'Lisbon');
      expect(content.state, english['headset_strip_playing']);
      expect(content.time, '1:02:15 / 1:58:00');
      expect(content.hint, isEmpty, reason: 'no hint while playing');
      expect(content.line3, isEmpty);

      for (final (hint, key) in [
        (HeadsetHint.stick, 'headset_strip_hint_stick'),
        (HeadsetHint.trackpad, 'headset_strip_hint_trackpad'),
        (HeadsetHint.simple, 'headset_strip_hint_simple'),
      ]) {
        content = headsetStripContentOf(
          t,
          idle: false,
          playback: const HeadsetPlayback(status: HeadsetPlaybackStatus.paused),
          hint: hint,
        );
        expect(content.state, english['headset_strip_paused']);
        expect(content.hint, english[key]);
      }
      content = headsetStripContentOf(
        t,
        idle: false,
        playback: const HeadsetPlayback(status: HeadsetPlaybackStatus.paused),
      );
      expect(content.hint, isEmpty);
      expect(content.line3, english['headset_strip_no_controller']);

      content = headsetStripContentOf(
        t,
        idle: false,
        playback: const HeadsetPlayback(status: HeadsetPlaybackStatus.buffering),
        hint: HeadsetHint.stick,
        memoryTight: true,
      );
      expect(content.state, english['headset_strip_buffering']);
      expect(content.line3, english['headset_strip_memory']);

      content = headsetStripContentOf(
        t,
        idle: false,
        playback: const HeadsetPlayback(status: HeadsetPlaybackStatus.ended),
        hint: HeadsetHint.stick,
        memoryTight: true,
        subtitle: 'Where are we going?',
      );
      expect(content.state, english['headset_strip_ended']);
      expect(content.line3, 'Where are we going?', reason: 'the subtitle line first');

      content = headsetStripContentOf(t, idle: true, hint: HeadsetHint.stick);
      expect(content.title, english['headset_strip_pick_video']);
    });
  });

  test('the hint of each profile of the binding table', () {
    expect(headsetHintOf('/interaction_profiles/khr/simple_controller', controllers: true), HeadsetHint.simple);
    expect(headsetHintOf('/interaction_profiles/htc/vive_controller', controllers: true), HeadsetHint.trackpad);
    for (final stick in [
      '/interaction_profiles/oculus/touch_controller',
      '/interaction_profiles/valve/index_controller',
      '/interaction_profiles/microsoft/motion_controller',
      '/interaction_profiles/hp/mixed_reality_controller',
      '/interaction_profiles/bytedance/pico4_controller',
      '/interaction_profiles/bytedance/pico_neo3_controller',
    ]) {
      expect(headsetHintOf(stick, controllers: true), HeadsetHint.stick, reason: stick);
    }
    expect(headsetHintOf('', controllers: true), HeadsetHint.none);
    expect(headsetHintOf('/interaction_profiles/oculus/touch_controller', controllers: false), HeadsetHint.none);
  });

  test('shows while paused, loading, ended or failed, 4 s after a change, in the dark room, with a subtitle', () {
    for (final status in HeadsetPlaybackStatus.values) {
      expect(
        headsetStripVisible(idle: false, status: status),
        status != HeadsetPlaybackStatus.playing,
        reason: status.name,
      );
    }
    const playing = HeadsetPlaybackStatus.playing;
    expect(headsetStripVisible(idle: true, status: playing), isTrue);
    expect(headsetStripVisible(idle: false, status: playing, subtitle: 'Hello'), isTrue);
    expect(headsetStripVisible(idle: false, status: playing, sinceFlash: const Duration(seconds: 3)), isTrue);
    expect(headsetStripVisible(idle: false, status: playing, sinceFlash: const Duration(seconds: 4)), isFalse);
  });

  group('the sender', () {
    test('no image again while the text is the same; the visibility alone sends no image', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 15);
        final sent = <({int bytes, bool visible})>[];
        final sender = HeadsetStripSender(
          render: (content) async => Uint8List(headsetStripWidth * headsetStripHeight * 4),
          send: (rgba, width, height, {required visible}) async => sent.add((bytes: rgba.length, visible: visible)),
          now: () => start.add(async.elapsed),
        );
        const content = HeadsetStripContent(title: 'Lisbon', state: 'Paused');
        sender.update(content, visible: true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        sender.update(content, visible: true);
        async.elapse(const Duration(seconds: 1));
        expect(sent, [(bytes: headsetStripWidth * headsetStripHeight * 4, visible: true)]);
        sender.update(content, visible: false);
        async.elapse(const Duration(milliseconds: 10));
        expect(sent.last, (bytes: 0, visible: false));
        expect(sender.images, 1);
      });
    });

    test('at most 4 images a second under a stream of positions, the newest one last', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 15);
        final drawn = <HeadsetStripContent>[];
        final sender = HeadsetStripSender(
          render: (content) async {
            drawn.add(content);
            return Uint8List(4);
          },
          send: (rgba, width, height, {required visible}) async {},
          now: () => start.add(async.elapsed),
        );
        // 50 a second for 2 s
        for (var i = 0; i < 100; i++) {
          sender.update(HeadsetStripContent(time: '0:$i'), visible: true);
          async.elapse(const Duration(milliseconds: 20));
        }
        async.elapse(const Duration(seconds: 1));
        expect(drawn.length, lessThanOrEqualTo(9));
        expect(drawn.length, greaterThanOrEqualTo(7));
        expect(drawn.last.time, '0:99');
      });
    });
  });

  test('the service: the strip follows the page and hides 4 s after a change while playing', () {
    fakeAsync((async) {
      final start = DateTime(2026, 11, 15);
      final api = FakeHeadsetApi();
      final page = FakePage();
      final service = HeadsetViewService(
        api: api,
        settings: _MemorySettings(),
        renderStrip: (content, font) async => Uint8List(headsetStripWidth * headsetStripHeight * 4),
        onNotice: (_) {},
        appVersion: () async => '3.4.2',
        now: () => start.add(async.elapsed),
        pollInterval: const Duration(hours: 1),
      );
      service.register(page.target);
      async.flushMicrotasks();
      unawaited(service.start(HeadsetChoice.around));
      async.elapse(const Duration(milliseconds: 300));
      expect(api.strips.first.visible, isTrue, reason: 'shown at the start');
      async.elapse(const Duration(seconds: 5));
      expect(api.strips.last, (bytes: 0, visible: false), reason: 'hidden 4 s later while it plays');
      page.target.playPause();
      async.elapse(const Duration(milliseconds: 300));
      expect(api.strips.last.visible, isTrue, reason: 'paused');
      service.dispose();
    });
  });
}

/// Settings kept in memory only, for a service under fake time
class _MemorySettings extends HeadsetViewSettings {
  @override
  Future<void> load() async {}

  @override
  Future<void> markRunning() async {}

  @override
  Future<void> clearRunning({required bool good}) async {}

  @override
  Future<String> newLogPath({DateTime? now}) async => '/tmp/headset/headset-20261115-000000.log';
}
