// The stabilisation of raw 360° videos in the player of the computers (issue 14, lot d2): the switch follows the rules
// of the Android player (StabilizationSwitchTest.kt), the messages wait for the player of their URL, the table goes to
// renderer C as it came, and the setting shows where renderer C draws the view (Windows) only.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_spherical_video_api.dart';
import 'package:immich_mobile/desktop/video/desktop_stabilization.dart';
import 'package:media_kit_video/sphere.dart';

PluginStabilization _table() => PluginStabilization(
  timesUs: Int64List.fromList([0, 33367]),
  corrections: Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0]),
);

void main() {
  group('the switch, as the Android player\'s', () {
    test('a raw video with a track is stabilised once the table comes', () {
      final table = _table();
      final stabilization = StabilizationSwitch();
      expect(stabilization.buttonVisible, isFalse, reason: 'nothing known yet: no button');

      expect(stabilization.onTrack(hasTrack: true), isNull);
      expect(stabilization.track, StabilizationTrack.pending);
      expect(stabilization.buttonVisible, isTrue);
      expect(stabilization.active, isFalse);

      expect(stabilization.onTrack(hasTrack: true, table: table), isNull);
      expect(stabilization.track, StabilizationTrack.ready);
      expect(stabilization.table, same(table));
      expect(stabilization.active, isTrue);
      // The first corrected frames say so, once
      expect(stabilization.onStabilized(), StabilizationNotice.stabilized);
      expect(stabilization.onStabilized(), isNull);
    });

    test('off gives the raw video, back on says so at once', () {
      final stabilization = StabilizationSwitch()..onTrack(hasTrack: true, table: _table());
      expect(stabilization.toggle(), isNull, reason: 'turned off: no notice');
      expect(stabilization.enabled, isFalse);
      expect(stabilization.active, isFalse);
      expect(stabilization.buttonVisible, isTrue, reason: 'the button stays, dimmed');
      expect(stabilization.toggle(), StabilizationNotice.stabilized);
      expect(stabilization.active, isTrue);
      expect(stabilization.onStabilized(), isNull, reason: 'told already');
    });

    test('a file without a track says so only when the user turned the switch on', () {
      final quiet = StabilizationSwitch()..onTrack(hasTrack: true);
      expect(quiet.onTrack(hasTrack: false), isNull);
      expect(quiet.track, StabilizationTrack.none);
      expect(quiet.buttonVisible, isFalse);

      final asked = StabilizationSwitch(enabled: false)..onTrack(hasTrack: true);
      expect(asked.toggle(), isNull, reason: 'nothing to say while the track is read');
      expect(asked.onTrack(hasTrack: false), StabilizationNotice.noTrack);
      expect(asked.buttonVisible, isFalse);

      final changed = StabilizationSwitch(enabled: false)..onTrack(hasTrack: true);
      changed
        ..toggle()
        ..toggle();
      expect(changed.onTrack(hasTrack: false), isNull);
    });

    test('the setting moves the switch until the user presses it', () {
      final stabilization = StabilizationSwitch()..onSetting(false);
      expect(stabilization.enabled, isFalse);
      stabilization.onSetting(true);
      expect(stabilization.enabled, isTrue);
      stabilization
        ..toggle()
        ..onSetting(true);
      expect(stabilization.enabled, isFalse);
      expect(stabilization.wasTouched, isTrue);
    });

    test('a view that is not the stitched sphere hides the button and corrects nothing', () {
      final stabilization = StabilizationSwitch()..onTrack(hasTrack: true, table: _table());
      stabilization.stitched = false;
      expect(stabilization.buttonVisible, isFalse);
      expect(stabilization.active, isFalse);
      stabilization.stitched = true;
      expect(stabilization.buttonVisible, isTrue);
      expect(stabilization.active, isTrue);
    });
  });

  group('the inbox', () {
    test('keeps the latest message of each URL apart, until its player closes', () async {
      final inbox = DesktopStabilizationInbox();
      final heard = <DesktopStabilizationMessage>[];
      final subscription = inbox.messages.listen(heard.add);
      addTearDown(subscription.cancel);
      inbox
        ..post(const DesktopStabilizationMessage(url: 'a', enabled: true, hasTrack: true))
        ..post(const DesktopStabilizationMessage(url: 'b', enabled: false, hasTrack: false))
        ..post(DesktopStabilizationMessage(url: 'a', enabled: true, hasTrack: true, table: _table()));
      expect(heard.map((message) => message.url), ['a', 'b', 'a']);
      expect(inbox.latestFor('a')!.table, isNotNull);
      expect(inbox.latestFor('b')!.enabled, isFalse);
      inbox.forget('a');
      expect(inbox.latestFor('a'), isNull);
      expect(inbox.latestFor('b'), isNotNull);
    });

    test('the platform API posts what Flutter says, the table as renderer C takes it', () async {
      final inbox = DesktopStabilizationInbox();
      final api = DesktopSphericalVideoApi(stabilization: inbox);
      final times = Int64List.fromList([0, 33367, 66733]);
      final corrections = Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]);
      await api.setStabilization('file:///x4.insv', true, true, null, null, null);
      expect(inbox.latestFor('file:///x4.insv')!.hasTrack, isTrue);
      expect(inbox.latestFor('file:///x4.insv')!.table, isNull, reason: 'the track is being read');
      await api.setStabilization('file:///x4.insv', true, true, times, corrections, 'summary');
      final table = inbox.latestFor('file:///x4.insv')!.table!;
      expect(table.timesUs, same(times));
      expect(table.corrections, same(corrections));
      // No track: no table, whatever came with it
      await api.setStabilization('file:///plain.mp4', false, false, times, corrections, null);
      expect(inbox.latestFor('file:///plain.mp4')!.table, isNull);
    });
  });

  test('a table whose lengths do not match is none', () {
    expect(pluginStabilizationOf(null, Float64List(4)), isNull);
    expect(pluginStabilizationOf(Int64List(0), Float64List(0)), isNull);
    expect(pluginStabilizationOf(Int64List(2), Float64List(4)), isNull);
    expect(pluginStabilizationOf(Int64List(1), Float64List(4))!.length, 1);
  });

  test('the computers stabilise where renderer C draws the view: Windows with libmpv loaded', () {
    expect(desktopStabilizationSupported(windows: true, rendererSupported: true, videoAvailable: true), isTrue);
    expect(desktopStabilizationSupported(windows: true, rendererSupported: true, videoAvailable: false), isFalse);
    expect(
      desktopStabilizationSupported(windows: false, rendererSupported: false, videoAvailable: true),
      isFalse,
      reason: 'Linux and macOS play 360° videos flat',
    );
  });
}
