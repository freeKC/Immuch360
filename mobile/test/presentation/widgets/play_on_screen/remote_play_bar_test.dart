// The mini controller of a film playing on a screen: what it says of the screen, and what its buttons ask the
// controller (a fake here, the protocol is tested end to end in phone_play_provider_test.dart)

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_bar.widget.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

class _Controller extends RemotePlaybackController {
  final calls = <String>[];

  @override
  RemotePlayback? build() => null;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> seekBy(Duration delta) async => calls.add('seekBy ${delta.inSeconds}');

  @override
  Future<void> seekTo(Duration position) async => calls.add('seekTo ${position.inSeconds}');

  @override
  Future<void> track(PlayTrackKind kind, String? id) async => calls.add('track ${kind.wire} $id');

  @override
  Future<Duration> stop() async {
    calls.add('stop');
    return const Duration(seconds: 42);
  }

  @override
  void dismiss() => calls.add('dismiss');
}

final _screen = LinkedPeer(
  id: '0123456789abcdef',
  name: 'Living room TV',
  key: Uint8List(playLinkKeyBytes),
  linkedAt: DateTime.utc(2026, 11, 10),
  kind: PairingScreenKind.tv,
);

const _request = PlayOnRequest(
  sourceId: 'source-1',
  server: 'abcdef0123456789abcdef0123456789abcdef01',
  serverName: 'Home Plex',
  ratingKey: '77',
  title: 'Title 77',
);

const _audioFr = PlayTrack(kind: PlayTrackKind.audio, id: '1.0', label: 'Français', language: 'fr', selected: true);
const _audioEn = PlayTrack(kind: PlayTrackKind.audio, id: '1.1', label: 'English', language: 'en');
const _subtitleFr = PlayTrack(kind: PlayTrackKind.subtitle, id: '2.0', label: 'Français', language: 'fr');

RemotePlayback _playback(ScreenPlayPhase phase, {List<PlayTrack> tracks = const [], bool lost = false}) =>
    RemotePlayback(
      screen: _screen,
      request: _request,
      state: ScreenPlayState(
        seq: 3,
        phase: phase,
        positionMs: 65000,
        durationMs: 3723000,
        server: _request.server,
        item: '77',
        tracks: tracks,
      ),
      lost: lost,
    );

void main() {
  setUpAll(TestUtils.init);

  late _Controller controller;
  Duration? continuedAt;

  Future<void> show(WidgetTester tester, RemotePlayback playback, {bool continueHere = true}) async {
    playOnPhoneScreen(tester);
    controller = _Controller();
    continuedAt = null;
    await pumpPlayOn(
      tester,
      Scaffold(
        bottomNavigationBar: RemotePlayBar(
          playback: playback,
          onContinueHere: continueHere ? (position) => continuedAt = position : null,
        ),
      ),
      overrides: [remotePlaybackProvider.overrideWith(() => controller)],
    );
  }

  IconButton button(WidgetTester tester, String key) => tester.widget<IconButton>(find.byKey(Key(key)));

  for (final (phase, line) in [
    (ScreenPlayPhase.playing, 'Playing on Living room TV'),
    (ScreenPlayPhase.paused, 'Playing on Living room TV'),
    (ScreenPlayPhase.asking, 'Waiting for an answer on Living room TV…'),
    (ScreenPlayPhase.opening, 'Opening on Living room TV…'),
    (ScreenPlayPhase.buffering, 'Opening on Living room TV…'),
    (ScreenPlayPhase.ended, 'The film ended on Living room TV'),
    (ScreenPlayPhase.idle, 'Stopped on Living room TV'),
    (ScreenPlayPhase.failed, 'Living room TV could not play this film'),
  ]) {
    testWidgets('says "$line" when the screen is ${phase.wire}', (tester) async {
      await show(tester, _playback(phase));
      expect(find.text(line), findsOneWidget);
    });
  }

  testWidgets('the title, the position and the length the screen told', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    expect(find.text('Title 77'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('1:02:03'), findsOneWidget);
    expect(find.byKey(const Key('remote_play_bar_position')), findsOneWidget);
  });

  testWidgets('pause while it plays, minus 10 s, plus 30 s, stop', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    await tester.tap(find.byKey(const Key('remote_play_bar_play')));
    await tester.tap(find.byKey(const Key('remote_play_bar_back10')));
    await tester.tap(find.byKey(const Key('remote_play_bar_forward30')));
    await tester.tap(find.byKey(const Key('remote_play_bar_stop')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['pause', 'seekBy -10', 'seekBy 30', 'stop']);
    expect(button(tester, 'remote_play_bar_close').onPressed, isNull, reason: 'Stop, not close, while it plays');
  });

  testWidgets('play while it is paused', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.paused));
    await tester.tap(find.byKey(const Key('remote_play_bar_play')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['resume']);
  });

  testWidgets('no Audio button for one audio track, no Subtitles without any', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing, tracks: const [_audioFr]));
    expect(find.byKey(const Key('remote_play_bar_audio')), findsNothing);
    expect(find.byKey(const Key('remote_play_bar_subtitles')), findsNothing);
  });

  testWidgets('Audio lists the tracks of the screen, the one playing ticked', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing, tracks: const [_audioFr, _audioEn, _subtitleFr]));
    await tester.tap(find.byKey(const Key('remote_play_bar_audio')));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.widgetWithIcon(ListTile, Icons.check_rounded), findsOneWidget);
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['track audio 1.1']);
  });

  testWidgets('Subtitles offers Off first', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing, tracks: const [_audioFr, _subtitleFr]));
    await tester.tap(find.byKey(const Key('remote_play_bar_subtitles')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('play_bar_subtitles_off')), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['track subtitle null']);

    await tester.tap(find.byKey(const Key('remote_play_bar_subtitles')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Français'));
    await tester.pumpAndSettle();
    expect(controller.calls.last, 'track subtitle 2.0');
  });

  testWidgets('Continue on this phone stops the screen and gives its position', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    await tester.tap(find.byKey(const Key('remote_play_bar_continue_here')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['stop']);
    expect(continuedAt, const Duration(seconds: 42));
  });

  testWidgets('no Continue on this phone where nothing can take the film', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing), continueHere: false);
    expect(find.byKey(const Key('remote_play_bar_continue_here')), findsNothing);
  });

  testWidgets('a screen that no longer answers: the controls off, close on', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing, lost: true));
    expect(find.text('Living room TV no longer answers'), findsOneWidget);
    for (final key in ['remote_play_bar_play', 'remote_play_bar_back10', 'remote_play_bar_forward30']) {
      expect(button(tester, key).onPressed, isNull, reason: key);
    }
    expect(button(tester, 'remote_play_bar_stop').onPressed, isNull);
    await tester.tap(find.byKey(const Key('remote_play_bar_close')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['dismiss']);

    // Continue on this phone still takes the film where the screen was last seen, without asking it
    await tester.tap(find.byKey(const Key('remote_play_bar_continue_here')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['dismiss', 'dismiss']);
    expect(continuedAt, const Duration(milliseconds: 65000));
  });

  test('positions read as the players write them', () {
    expect(playPositionText(0), '0:00');
    expect(playPositionText(65000), '1:05');
    expect(playPositionText(3723000), '1:02:03');
    expect(playPositionText(-5), '0:00');
  });
}
