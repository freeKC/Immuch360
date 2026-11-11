// The dock of the mini controller at the bottom of the app, while a film plays on a screen and its page is gone: what
// it says, what its buttons ask the controller (a fake here), the page it opens, and how it keeps out of the way of a
// page with the whole controller and of the keyboard, without the navigator under it losing its pages

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_dock.widget.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

class _Controller extends RemotePlaybackController {
  _Controller(this.initial);

  final RemotePlayback? initial;
  final calls = <String>[];

  @override
  RemotePlayback? build() => initial;

  set playback(RemotePlayback? value) => state = value;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

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
  path: '/Films/Title 77.mkv',
);

RemotePlayback _playback(ScreenPlayPhase phase, {bool lost = false, PlayOnRequest request = _request}) =>
    RemotePlayback(
      screen: _screen,
      request: request,
      state: ScreenPlayState(
        seq: 3,
        phase: phase,
        positionMs: 1861500,
        durationMs: 3723000,
        server: request.server,
        item: '77',
      ),
      lost: lost,
    );

const _dock = Key('remote_play_dock');

void main() {
  setUpAll(TestUtils.init);

  late _Controller controller;
  late List<String?> opened;

  /// The page under the dock, with a button that opens a second page, and the bottom padding it is given
  double? pagePadding;

  Widget home() => Builder(
    builder: (context) {
      pagePadding = MediaQuery.paddingOf(context).bottom;
      return Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Center(child: Text('second page'))),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
    },
  );

  Future<void> show(WidgetTester tester, RemotePlayback? playback, {Widget? page}) async {
    playOnPhoneScreen(tester);
    tester.view.padding = const FakeViewPadding(bottom: 81);
    controller = _Controller(playback);
    opened = [];
    await pumpPlayOn(
      tester,
      page ?? home(),
      overrides: [remotePlaybackProvider.overrideWith(() => controller)],
      builder: (context, child) =>
          RemotePlayDock(openFilm: (ref, playback) => opened.add(playback.request.path), child: child!),
    );
  }

  testWidgets('nothing plays on a screen: no dock, and the page keeps the bottom padding of the phone', (tester) async {
    await show(tester, null);
    expect(find.byKey(_dock), findsNothing);
    expect(pagePadding, closeTo(30, 0.001));
  });

  testWidgets('a film plays on a screen: where, its title and position; pause and stop ask the controller', (
    tester,
  ) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    expect(find.byKey(_dock), findsOneWidget);
    expect(find.text('Playing on Living room TV'), findsOneWidget);
    expect(find.text('Title 77'), findsOneWidget);
    final position = tester.widget<LinearProgressIndicator>(find.byKey(const Key('remote_play_dock_position')));
    expect(position.value, closeTo(0.5, 0.001));
    expect(pagePadding, 0, reason: 'the dock takes the bottom padding, under the page');
    expect(find.byKey(const Key('remote_play_dock_close')), findsNothing);

    await tester.tap(find.byKey(const Key('remote_play_dock_play')));
    await tester.tap(find.byKey(const Key('remote_play_dock_stop')));
    await tester.pump();
    expect(controller.calls, ['pause', 'stop']);
  });

  testWidgets('paused on the screen: play resumes it', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.paused));
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    await tester.tap(find.byKey(const Key('remote_play_dock_play')));
    await tester.pump();
    expect(controller.calls, ['resume']);
  });

  for (final (name, playback, line) in [
    ('ended', _playback(ScreenPlayPhase.ended), 'The film ended on Living room TV'),
    ('stopped', _playback(ScreenPlayPhase.idle), 'Stopped on Living room TV'),
    ('lost', _playback(ScreenPlayPhase.playing, lost: true), 'Living room TV no longer answers'),
  ]) {
    testWidgets('$name: it says so, and Close alone lets it go', (tester) async {
      await show(tester, playback);
      expect(find.text(line), findsOneWidget);
      expect(find.byKey(const Key('remote_play_dock_play')), findsNothing);
      expect(find.byKey(const Key('remote_play_dock_stop')), findsNothing);
      await tester.tap(find.byKey(const Key('remote_play_dock_close')));
      await tester.pump();
      expect(controller.calls, ['dismiss']);
    });
  }

  testWidgets('a tap on the title opens the page of the film; none without the path of its file', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    await tester.tap(find.text('Title 77'));
    await tester.pump();
    expect(opened, ['/Films/Title 77.mkv']);

    const noPath = PlayOnRequest(
      sourceId: 'source-1',
      server: 'abcdef0123456789abcdef0123456789abcdef01',
      serverName: 'Home Plex',
      ratingKey: '77',
      title: 'Title 77',
    );
    controller.playback = _playback(ScreenPlayPhase.playing, request: noPath);
    await tester.pump();
    await tester.tap(find.text('Title 77'));
    await tester.pump();
    expect(opened, ['/Films/Title 77.mkv']);
  });

  testWidgets('a page with the whole controller: the dock keeps out of its way, and comes back once it is gone', (
    tester,
  ) async {
    final playback = _playback(ScreenPlayPhase.playing);
    await show(
      tester,
      playback,
      page: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: const Center(child: Text('film page')),
                    bottomNavigationBar: RemotePlayBar(playback: playback),
                  ),
                ),
              ),
              child: const Text('open the film'),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(_dock), findsOneWidget);

    await tester.tap(find.text('open the film'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remote_play_bar')), findsOneWidget);
    expect(find.byKey(_dock), findsNothing);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remote_play_bar')), findsNothing);
    expect(find.byKey(_dock), findsOneWidget);
  });

  testWidgets('the keyboard up: no dock until it goes down', (tester) async {
    await show(tester, _playback(ScreenPlayPhase.playing));
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pump();
    expect(find.byKey(_dock), findsNothing);
    tester.view.resetViewInsets();
    await tester.pump();
    expect(find.byKey(_dock), findsOneWidget);
  });

  testWidgets('the dock comes and goes: the navigator keeps the page that was open', (tester) async {
    await show(tester, null);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);

    controller.playback = _playback(ScreenPlayPhase.playing);
    await tester.pump();
    expect(find.byKey(_dock), findsOneWidget);
    expect(find.text('second page'), findsOneWidget);

    controller.playback = null;
    await tester.pump();
    expect(find.byKey(_dock), findsNothing);
    expect(find.text('second page'), findsOneWidget);
  });

  group('playsOnScreen', () {
    test('the same file of the same source while the screen plays it, not once it ended or went', () {
      final playing = _playback(ScreenPlayPhase.playing);
      expect(playing.playsOnScreen('source-1', '/Films/Title 77.mkv'), isTrue);
      expect(_playback(ScreenPlayPhase.opening).playsOnScreen('source-1', '/Films/Title 77.mkv'), isTrue);
      expect(playing.playsOnScreen('source-2', '/Films/Title 77.mkv'), isFalse);
      expect(playing.playsOnScreen('source-1', '/Films/Other.mkv'), isFalse);
      expect(_playback(ScreenPlayPhase.ended).playsOnScreen('source-1', '/Films/Title 77.mkv'), isFalse);
      expect(_playback(ScreenPlayPhase.failed).playsOnScreen('source-1', '/Films/Title 77.mkv'), isFalse);
      expect(_playback(ScreenPlayPhase.playing, lost: true).playsOnScreen('source-1', '/Films/Title 77.mkv'), isFalse);
      expect(_playback(ScreenPlayPhase.ended).isOf('source-1', '/Films/Title 77.mkv'), isTrue);
    });
  });
}
