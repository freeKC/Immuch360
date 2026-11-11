// The "Play on" sheet of a film on a phone: This phone, the linked screens with their state, the handover button of
// a screen without the server, and how to link a first screen

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

const _tvId = '0123456789abcdef';
const _questId = '1123456789abcdef';
const _machine = 'abcdef0123456789abcdef0123456789abcdef01';

LinkedPeer _screen(String id, String name, PairingScreenKind kind) =>
    LinkedPeer(id: id, name: name, key: Uint8List(playLinkKeyBytes), linkedAt: DateTime.utc(2026, 11, 10), kind: kind);

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

const _request = PlayOnRequest(sourceId: 'source-1', server: _machine, serverName: 'Home Plex', ratingKey: '77');

void main() {
  setUpAll(TestUtils.init);

  Future<void> open(
    WidgetTester tester, {
    List<LinkedPeer> screens = const [],
    Map<String, PlayScreenAddress> nearby = const {},
    Map<String, Set<String>> withoutServer = const {},
    void Function(bool)? answered,
  }) async {
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      playOnOpener((context) async {
        final playing = await showPlayOnSheet(context, _request);
        answered?.call(playing);
      }),
      overrides: [
        linkedScreensProvider.overrideWith(() => _Screens(screens)),
        nearbyPlayScreensProvider.overrideWith(() => _Nearby(nearby)),
        screensWithoutServerProvider.overrideWith((_) => withoutServer),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ListTile tile(WidgetTester tester, String id) => tester.widget<ListTile>(find.byKey(ValueKey('play_on_$id')));

  testWidgets('with no linked screen, how to link one, and Add a screen', (tester) async {
    await open(tester);
    expect(find.text('Play on…'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.byKey(const Key('play_on_empty')), findsOneWidget);
    expect(find.textContaining('Settings, Play from a phone, Link a phone'), findsOneWidget);
    expect(find.text('Your screens'), findsNothing);
    expect(find.text('Add a screen'), findsOneWidget);
  });

  testWidgets('a linked screen not announced asks to open the app on it, and cannot be chosen', (tester) async {
    await open(
      tester,
      screens: [
        _screen(_tvId, 'Living room TV', PairingScreenKind.tv),
        _screen(_questId, 'Quest 3', PairingScreenKind.headset),
      ],
    );
    expect(find.text('Your screens'), findsOneWidget);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Open Immuch360 on it'), findsOneWidget);
    expect(find.text('Put on the headset and open Immuch360'), findsOneWidget);
    expect(tile(tester, _tvId).enabled, isFalse);
    expect(tile(tester, _tvId).onTap, isNull);
    expect(tile(tester, _questId).enabled, isFalse);
    expect(find.byKey(const Key('play_on_empty')), findsNothing);
  });

  testWidgets('an announced screen is Ready', (tester) async {
    await open(
      tester,
      screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
      nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
    );
    expect(find.text('Ready'), findsOneWidget);
    expect(tile(tester, _tvId).enabled, isTrue);
    expect(tile(tester, _tvId).onTap, isNotNull);
  });

  testWidgets('a screen that said it lacks the server offers Add (server) to (screen)', (tester) async {
    await open(
      tester,
      screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
      nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
      withoutServer: {
        _tvId: {_machine},
      },
    );
    expect(find.text('Does not have Home Plex yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('play_on_add_server_$_tvId')), findsOneWidget);
    expect(find.text('Add Home Plex to Living room TV'), findsOneWidget);
    expect(tile(tester, _tvId).onTap, isNull, reason: 'the button, not the row');
  });

  testWidgets('another server missing on that screen does not matter', (tester) async {
    await open(
      tester,
      screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
      nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
      withoutServer: {
        _tvId: {'0000000000000000000000000000000000000002'},
      },
    );
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('play_on_add_server_$_tvId')), findsNothing);
  });

  testWidgets('This phone closes the sheet: the film stays here', (tester) async {
    bool? playing;
    await open(tester, answered: (value) => playing = value);
    await tester.tap(find.byKey(const Key('play_on_this_phone')));
    await tester.pumpAndSettle();
    expect(playing, isFalse);
    expect(find.byKey(const Key('play_on_sheet')), findsNothing);
  });

  test('the state of a row', () {
    final tv = _screen(_tvId, 'TV', PairingScreenKind.tv);
    const address = (host: '192.168.1.20', port: 8363);
    expect(
      playScreenRowState(screen: tv, nearby: const {}, withoutServer: const {}, server: _machine),
      PlayScreenRowState.notAnnounced,
    );
    expect(
      playScreenRowState(screen: tv, nearby: const {_tvId: address}, withoutServer: const {}, server: _machine),
      PlayScreenRowState.ready,
    );
    expect(
      playScreenRowState(
        screen: tv,
        nearby: const {_tvId: address},
        withoutServer: const {
          _tvId: {_machine},
        },
        server: _machine,
      ),
      PlayScreenRowState.withoutServer,
    );
    // Not announced wins: the handover needs the screen to answer
    expect(
      playScreenRowState(
        screen: tv,
        nearby: const {},
        withoutServer: const {
          _tvId: {_machine},
        },
        server: _machine,
      ),
      PlayScreenRowState.notAnnounced,
    );
  });
}
