// The "Play on" sheet with its two groups: the linked screens, then the Cast devices (experimental) with what the Plex
// metadata says of the film on each, the question before casting to one that cannot play it, the controls of a cast,
// and the dock of a cast on the other pages

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_dock.widget.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

const _tvId = '0123456789abcdef';

class _Screens extends LinkedPeersNotifier {
  _Screens(this.initial) : super(playLinkScreensKey, maxLinkedScreens);

  final List<LinkedPeer> initial;

  @override
  Future<List<LinkedPeer>> build() async => initial;
}

class _Nearby extends NearbyPlayScreensNotifier {
  _Nearby(this.initial);

  final Map<String, PlayScreenAddress> initial;

  @override
  Map<String, PlayScreenAddress> build() => initial;
}

class _Devices extends CastDevicesNotifier {
  _Devices(this.initial);

  final CastDiscovery initial;

  @override
  CastDiscovery build() => initial;
}

/// Records the casts asked; a cast starts paused at once (no ticking position in the test)
class _Cast extends CastPlaybackController {
  _Cast([this.initial]);

  final CastPlayback? initial;
  final List<String> casts = [];
  int stops = 0;

  @override
  CastPlayback? build() => initial;

  @override
  Future<CastOutcome> cast(CastTarget target, PlayOnRequest request) async {
    casts.add(target.id);
    state = CastPlayback(
      target: target,
      request: request,
      title: 'Amélie',
      phase: CastPhase.paused,
      at: DateTime.utc(2026, 11, 11),
      positionMs: 61000,
      durationMs: 7320000,
      volume: 0.5,
    );
    return CastOutcome.playing;
  }

  @override
  Future<void> stop() async {
    stops++;
    state = null;
  }
}

const _request = PlayOnRequest(
  sourceId: 'source-1',
  server: 'abcdef0123456789abcdef0123456789abcdef01',
  serverName: 'Home Plex',
  ratingKey: '77',
  title: 'Amélie',
);

const _living = CastTarget(
  id: 'cc-1',
  name: 'Living room',
  host: '192.168.1.42',
  port: 8009,
  model: 'Chromecast Ultra',
);
const _hub = CastTarget(id: 'hub-1', name: 'Kitchen', host: '192.168.1.43', port: 8009, model: 'Google Nest Hub');

/// The Android TV running Immuch360, also a Cast device: left to its row in Your screens
const _tvCast = CastTarget(id: 'tv-1', name: 'Living room TV (Cast)', host: '192.168.1.30', port: 8009);

const _info = CastFilmInfo(
  title: 'Amélie',
  path: '/.item/77/amelie.mp4',
  format: CastFilmFormat(container: 'mp4', videoCodec: 'hevc', audioCodec: 'aac', width: 1920, height: 1080),
);

void main() {
  setUpAll(TestUtils.init);

  /// [settle] false while a spinner turns
  Future<_Cast> open(WidgetTester tester, {CastDiscovery? discovery, CastPlayback? playing, bool settle = true}) async {
    final cast = _Cast(playing);
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      playOnOpener((context) => showPlayOnSheet(context, _request)),
      overrides: [
        linkedScreensProvider.overrideWith(
          () => _Screens([
            LinkedPeer(
              id: _tvId,
              name: 'Living room TV',
              key: Uint8List(playLinkKeyBytes),
              linkedAt: DateTime.utc(2026, 11, 10),
              kind: PairingScreenKind.tv,
            ),
          ]),
        ),
        nearbyPlayScreensProvider.overrideWith(() => _Nearby({_tvId: (host: '192.168.1.30', port: 8363)})),
        castDevicesProvider.overrideWith(
          () => _Devices(
            discovery ?? const CastDiscovery(byService: {'a': _living, 'b': _hub, 'c': _tvCast}, searching: false),
          ),
        ),
        castFilmInfoProvider.overrideWith((ref, key) async => _info),
        castPlaybackProvider.overrideWith(() => cast),
      ],
    );
    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(seconds: 1));
    }
    return cast;
  }

  testWidgets('two groups: Your screens, then the Cast devices, labelled experimental, with their verdicts', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Your screens'), findsOneWidget);
    expect(find.byKey(const ValueKey('play_on_$_tvId')), findsOneWidget);
    expect(find.text('Cast devices'), findsOneWidget);
    expect(find.text('Experimental'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Your screens')).dy, lessThan(tester.getTopLeft(find.text('Cast devices')).dy));

    // The TV that runs Immuch360 is not listed twice
    expect(find.byKey(const ValueKey('cast_tv-1')), findsNothing);
    expect(find.byKey(const ValueKey('cast_cc-1')), findsOneWidget);
    expect(find.textContaining('Should play this film'), findsOneWidget);
    expect(find.textContaining('Cannot play it: HEVC video'), findsOneWidget);
    // Sorted by name
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('cast_hub-1'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('cast_cc-1'))).dy),
    );
  });

  testWidgets('a device that cannot play the film asks first; Cancel casts nothing, Try anyway casts', (tester) async {
    final cast = await open(tester);
    await tester.tap(find.byKey(const ValueKey('cast_hub-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cast_cannot_dialog')), findsOneWidget);
    expect(find.text('Kitchen cannot play this film'), findsOneWidget);
    expect(find.textContaining('HEVC video. Cast devices decode a few formats only'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cast.casts, isEmpty);

    await tester.tap(find.byKey(const ValueKey('cast_hub-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cast_try_anyway')));
    await tester.pumpAndSettle();
    expect(cast.casts, ['hub-1']);
  });

  testWidgets('a cast that plays shows its controls in the sheet: the device, the title, the times, Stop', (
    tester,
  ) async {
    final cast = await open(tester);
    await tester.tap(find.byKey(const ValueKey('cast_cc-1')));
    await tester.pumpAndSettle();
    expect(cast.casts, ['cc-1']);
    expect(find.byKey(const Key('cast_controls')), findsOneWidget);
    expect(find.text('Casting to Living room'), findsOneWidget);
    expect(find.byKey(const Key('cast_controls_time')), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    expect(find.text('2:02:00'), findsOneWidget);
    expect(find.byKey(const Key('cast_controls_volume')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cast_controls_stop')));
    await tester.pumpAndSettle();
    expect(cast.stops, 1);
    expect(find.byKey(const Key('cast_controls')), findsNothing);
  });

  testWidgets('while looking', (tester) async {
    await open(tester, discovery: const CastDiscovery(), settle: false);
    expect(find.text('Looking for Cast devices on this network…'), findsOneWidget);
  });

  testWidgets('no Cast device found', (tester) async {
    await open(tester, discovery: const CastDiscovery(searching: false));
    expect(find.text('No Cast device found on this network'), findsOneWidget);
  });

  testWidgets('the dock shows the cast on the other pages, opens its controls, and stops it', (tester) async {
    final cast = _Cast(
      CastPlayback(
        target: _living,
        request: _request,
        title: 'Amélie',
        phase: CastPhase.paused,
        at: DateTime.utc(2026, 11, 11),
        positionMs: 61000,
        durationMs: 7320000,
      ),
    );
    final opened = <String>[];
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      const Scaffold(body: Center(child: Text('another page'))),
      overrides: [castPlaybackProvider.overrideWith(() => cast)],
      builder: (context, child) =>
          RemotePlayDock(openCast: (ref, playback) => opened.add(playback.target.id), child: child!),
    );
    expect(find.byKey(const Key('cast_dock')), findsOneWidget);
    expect(find.text('Casting to Living room'), findsOneWidget);
    expect(find.text('Amélie'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cast_dock_open')));
    expect(opened, ['cc-1']);
    await tester.tap(find.byKey(const Key('cast_dock_stop')));
    await tester.pumpAndSettle();
    expect(cast.stops, 1);
    expect(find.byKey(const Key('cast_dock')), findsNothing);
  });
}
