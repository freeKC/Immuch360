// The status strip of the headset view (lib/desktop/video/xr/headset_strip.dart): its size and opaque background, its
// texts per state, the hint per controller profile, when it shows, and its images sent only when the text changed, at
// most 4 a second.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
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

  group('the hint fits its place, whole, in every language', () {
    // The app's font, as the strip draws it on a computer
    setUpAll(() async {
      final font = FontLoader('GoogleSans');
      for (final face in ['Regular', 'SemiBold']) {
        final bytes = File('fonts/GoogleSans/GoogleSans-$face.ttf').readAsBytesSync();
        font.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await font.load();
    });

    // A film of nearly two hours, the widest time of most videos
    const time = '1:02:15 / 1:58:00';
    const hints = ['headset_strip_hint_stick', 'headset_strip_hint_trackpad', 'headset_strip_hint_simple'];

    void expectWhole(HeadsetStripLayout layout, String reason) {
      final hint = layout.hint!;
      expect(hint.whole, isTrue, reason: '$reason: no line cut');
      expect(hint.width, lessThanOrEqualTo(layout.hintRoom + 0.5), reason: '$reason: within its width');
      expect(hint.rect.top, greaterThanOrEqualTo(layout.title.rect.bottom - 0.5), reason: '$reason: under line 1');
      expect(hint.rect.bottom, lessThanOrEqualTo(106), reason: '$reason: above line 3');
      final time = layout.time.rect;
      expect(hint.rect.left >= time.right || hint.rect.right <= time.left, isTrue, reason: '$reason: beside the time');
      expect(hint.rect.left, greaterThanOrEqualTo(24 - 0.5), reason: '$reason: within the strip');
      expect(hint.rect.right, lessThanOrEqualTo(headsetStripWidth - 24 + 0.5), reason: '$reason: within the strip');
    }

    test('the English hints on one line at full size, with room to spare', () {
      for (final key in hints) {
        final text = english[key]! as String;
        final layout = layoutHeadsetStrip(
          HeadsetStripContent(title: 'Lisbon', state: 'Paused', time: time, hint: text),
          fontFamily: 'GoogleSans',
        );
        expectWhole(layout, key);
        final hint = layout.hint!;
        expect(hint.scale, 1, reason: key);
        expect(hint.painter.text!.style!.fontSize, headsetHintSize, reason: '$key at full size');
        expect(hint.painter.computeLineMetrics(), hasLength(1), reason: '$key on one line');
        expect(hint.width, lessThan(layout.hintRoom * 0.93), reason: '$key: ${hint.width} of ${layout.hintRoom} px');
      }
    });

    test('a hint far too long shrinks, wraps and scales down, its last words kept', () {
      final long = List.filled(4, english['headset_strip_hint_stick']! as String).join(' ');
      for (final direction in TextDirection.values) {
        final layout = layoutHeadsetStrip(
          HeadsetStripContent(title: 'Lisbon', state: 'Paused', time: time, hint: long),
          fontFamily: 'GoogleSans',
          direction: direction,
        );
        expectWhole(layout, direction.name);
        expect(layout.hint!.painter.plainText, long);
      }
    });

    test('the hints of the 88 translations are drawn whole', () {
      final files = Directory('../i18n').listSync().whereType<File>().where((file) => file.path.endsWith('.json'));
      expect(files.length, greaterThan(80));
      for (final file in files) {
        final texts = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final language = file.uri.pathSegments.last.replaceAll('.json', '');
        for (final key in hints) {
          final text = texts[key];
          if (text is! String || text.isEmpty) {
            continue;
          }
          final layout = layoutHeadsetStrip(
            HeadsetStripContent(title: 'Lisbon', state: 'Paused', time: time, hint: text),
            fontFamily: 'GoogleSans',
            direction: headsetStripDirectionOf(Locale(language.split('_').first)),
          );
          expectWhole(layout, '$language $key');
        }
      }
    });
  });

  group('the reading direction', () {
    test('right to left for Arabic, Persian, Hebrew and Urdu', () {
      for (final language in ['ar', 'fa', 'he', 'ur']) {
        expect(headsetStripDirectionOf(Locale(language)), TextDirection.rtl, reason: language);
      }
      for (final language in ['en', 'fr', 'de', 'ja', 'zh']) {
        expect(headsetStripDirectionOf(Locale(language)), TextDirection.ltr, reason: language);
      }
      expect(headsetStripDirectionOf(null), TextDirection.ltr);
    });

    test('mirrored right to left: the title and the time at the right, the state at the left', () {
      const content = HeadsetStripContent(
        title: 'لشبونة',
        state: 'متوقف',
        time: '1:02:15 / 1:58:00',
        hint: 'الزناد: تشغيل',
        line3: 'نص',
      );
      final ltr = layoutHeadsetStrip(content);
      final rtl = layoutHeadsetStrip(content, direction: TextDirection.rtl);
      const width = headsetStripWidth * 1.0;
      expect(ltr.title.rect.left, 24);
      expect(rtl.title.rect.right, closeTo(width - 24, 0.01));
      expect(ltr.state.rect.right, closeTo(width - 24, 0.01));
      expect(rtl.state.rect.left, closeTo(24, 0.01));
      expect(rtl.time.rect.right, closeTo(width - 24, 0.01));
      expect(rtl.hint!.rect.right, closeTo(width - 48 - rtl.time.width, 0.01));
      expect(rtl.line3!.rect.right, closeTo(width - 24, 0.01));
      for (final text in [rtl.title, rtl.state, rtl.hint!, rtl.line3!]) {
        expect(text.painter.textDirection, TextDirection.rtl);
      }
      expect(rtl.time.painter.textDirection, TextDirection.ltr, reason: 'the figures of the time read left to right');
    });
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

  test('the service draws the strip in the direction of the app language', () {
    fakeAsync((async) {
      final directions = <TextDirection>[];
      final service = HeadsetViewService(
        api: FakeHeadsetApi(),
        settings: _MemorySettings(),
        renderStrip: (content, font, direction) async {
          directions.add(direction);
          return Uint8List(headsetStripWidth * headsetStripHeight * 4);
        },
        onNotice: (_) {},
        appVersion: () async => '3.4.2',
        pollInterval: const Duration(hours: 1),
      );
      final page = FakePage();
      service.register(page.target);
      async.flushMicrotasks();
      unawaited(service.start(HeadsetChoice.around, locale: const Locale('ar')));
      async.elapse(const Duration(milliseconds: 300));
      expect(directions, isNotEmpty);
      expect(directions.toSet(), {TextDirection.rtl});
      service.dispose();
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
        renderStrip: (content, font, direction) async => Uint8List(headsetStripWidth * headsetStripHeight * 4),
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
