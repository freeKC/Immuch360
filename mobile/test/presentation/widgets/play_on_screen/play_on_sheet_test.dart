// The "Play on" sheet of a film on a phone: This phone, the linked screens with their state, the handover button of
// a screen without the server, and how to link a first screen

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/presentation/widgets/cast/cast_group.widget.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_relay.provider.dart';
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

/// The playback of the phone: what the sheet asked it to play, and what each play ends in
class _Remote extends RemotePlaybackController {
  _Remote(this.answer);

  final PlayOnOutcome Function(PlayOnRequest request) answer;
  final played = <PlayOnRequest>[];

  @override
  Future<PlayOnOutcome> play(LinkedPeer screen, PlayScreenAddress address, PlayOnRequest request) async {
    played.add(request);
    return answer(request);
  }
}

/// The keep alive of an iPhone: the app must stay open while it sends
class _IosKeepAlive implements PlayRelayKeepAlive {
  @override
  Future<void> start({
    required String title,
    required String text,
    required String stopLabel,
    required String channel,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get stopRequests => const Stream.empty();

  @override
  bool get needsAppOpen => true;
}

const _request = PlayOnRequest(sourceId: 'source-1', server: _machine, serverName: 'Home Plex', ratingKey: '77');

void main() {
  setUpAll(TestUtils.init);

  Future<void> open(
    WidgetTester tester, {
    List<LinkedPeer> screens = const [],
    Map<String, PlayScreenAddress> nearby = const {},
    Map<String, Set<String>> withoutServer = const {},
    Set<String> signedOut = const {},
    void Function(bool)? answered,
    PlayOnRequest request = _request,
    _Remote? remote,
    bool iPhone = false,
  }) async {
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      playOnOpener((context) async {
        final playing = await showPlayOnSheet(context, request);
        answered?.call(playing);
      }),
      overrides: [
        linkedScreensProvider.overrideWith(() => _Screens(screens)),
        nearbyPlayScreensProvider.overrideWith(() => _Nearby(nearby)),
        screensWithoutServerProvider.overrideWith((_) => withoutServer),
        screensSignedOutProvider.overrideWith((_) => signedOut),
        if (remote != null) remotePlaybackProvider.overrideWith(() => remote),
        if (iPhone)
          phoneRelayEnvironmentProvider.overrideWithValue(
            PhoneRelayEnvironment(
              addressFor: (_) async => null,
              bind: (address) => CastRelayServer.bind(address),
              keepAlive: _IosKeepAlive(),
              texts: () => (title: (s) => s, text: '', stopLabel: '', channel: ''),
            ),
          ),
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
    // Signed out: for an Immich item only
    expect(
      playScreenRowState(
        screen: tv,
        nearby: const {_tvId: address},
        withoutServer: const {},
        server: 'immich',
        signedOut: const {_tvId},
        immich: true,
      ),
      PlayScreenRowState.signedOut,
    );
    expect(
      playScreenRowState(
        screen: tv,
        nearby: const {_tvId: address},
        withoutServer: const {},
        server: _machine,
        signedOut: const {_tvId},
      ),
      PlayScreenRowState.ready,
    );
  });

  group('Immich', () {
    PlayOnRequest photo({AssetVisibility visibility = AssetVisibility.timeline}) => PlayOnRequest.ofAsset(
      RemoteAsset(
        id: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        name: 'IMG_0001.jpg',
        ownerId: 'a1b2c3d4-0000-4000-8000-00000000abcd',
        checksum: 'c',
        type: AssetType.image,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        visibility: visibility,
        isEdited: false,
      ),
      userId: 'a1b2c3d4-0000-4000-8000-00000000abcd',
      endpoints: const [],
      serverName: 'photos.example.org',
    )!;

    testWidgets('a screen that said it is signed out offers to sign it in, and can still be tried', (tester) async {
      await open(
        tester,
        request: photo(),
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
        signedOut: {_tvId},
      );
      expect(find.text('Not signed in to photos.example.org'), findsOneWidget);
      expect(find.text('Sign Living room TV in to photos.example.org'), findsOneWidget);
      expect(tile(tester, _tvId).onTap, isNotNull);
    });

    testWidgets('with no linked screen, the text speaks of photos and videos', (tester) async {
      await open(tester, request: photo());
      expect(find.textContaining('Show your photos and videos on the TV'), findsOneWidget);
    });

    testWidgets('a locked item is never sent to a screen: the sheet says so and sends nothing', (tester) async {
      await open(
        tester,
        request: photo(visibility: AssetVisibility.locked),
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
      );
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pump();
      expect(find.text('Items of the locked folder are never shown on a screen'), findsOneWidget);
      expect(find.byKey(const Key('play_on_private_dialog')), findsNothing);
    });

    testWidgets('an archived item asks first; Cancel sends nothing', (tester) async {
      await open(
        tester,
        request: photo(visibility: AssetVisibility.archive),
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
      );
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pumpAndSettle();
      expect(find.text('Show an archived item on Living room TV?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('play_on_private_dialog')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('sent from this phone (release 53)', () {
    PlayOnRequest remotePhoto() => PlayOnRequest.ofAsset(
      RemoteAsset(
        id: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        name: 'IMG_0001.HEIC',
        ownerId: 'a1b2c3d4-0000-4000-8000-00000000abcd',
        checksum: 'c',
        type: AssetType.image,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        isEdited: false,
      ),
      userId: 'a1b2c3d4-0000-4000-8000-00000000abcd',
      endpoints: const [],
      serverName: 'photos.example.org',
    )!;

    final local = PlayOnRequest.relayed(
      sourceId: playOnLocalSource,
      serverName: '',
      title: 'PXL_0001.mp4',
      localAssetId: '1234',
      relay: PlayOnRelayItem(
        key: 'local:1234',
        name: 'PXL_0001.mp4',
        media: PlayMedia.video,
        content: () async => null,
      ),
    );

    testWidgets(
      'a screen of another account offers Send it from this phone, which sends the same item from the relay',
      (tester) async {
        final remote = _Remote((request) => request.relay == null ? PlayOnOutcome.otherAccount : PlayOnOutcome.playing);
        bool? playing;
        await open(
          tester,
          request: remotePhoto(),
          screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
          nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
          remote: remote,
          answered: (value) => playing = value,
        );
        expect(find.text('Send it from this phone'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
        await tester.pumpAndSettle();
        expect(find.text('Living room TV uses another Immich account, which cannot see this'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('play_on_send_from_phone_$_tvId')));
        await tester.pumpAndSettle();
        expect(remote.played, hasLength(2));
        final sent = remote.played.last;
        expect(sent.kind, PlayKind.relay);
        expect(sent.immich?.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
        expect(sent.relay?.name, 'IMG_0001.jpg', reason: 'the server\'s JPEG of a HEIC photo');
        expect(playing, isTrue);
      },
    );

    testWidgets('a screen that does not have the share offers it too; a refusal of another kind does not', (
      tester,
    ) async {
      var outcome = PlayOnOutcome.declined;
      final remote = _Remote((_) => outcome);
      await open(
        tester,
        request: remotePhoto(),
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
        remote: remote,
      );
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pumpAndSettle();
      expect(find.text('Send it from this phone'), findsNothing);
      outcome = PlayOnOutcome.notVisible;
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pumpAndSettle();
      expect(find.text('Send it from this phone'), findsOneWidget);
      expect(playOnSendableFromPhone(PlayOnOutcome.noSuchSource), isTrue);
      expect(playOnSendableFromPhone(PlayOnOutcome.otherServer), isTrue);
      expect(playOnSendableFromPhone(PlayOnOutcome.locked), isFalse);
      expect(playOnSendableFromPhone(PlayOnOutcome.unreachable), isFalse);
    });

    testWidgets('an item on this phone only: a note, no Cast device, and the screen plays it', (tester) async {
      final remote = _Remote((_) => PlayOnOutcome.playing);
      await open(
        tester,
        request: local,
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
        remote: remote,
      );
      expect(find.text('On this phone only: Immuch360 sends it to the screen from here'), findsOneWidget);
      expect(find.byType(CastGroup), findsNothing);
      expect(find.byKey(const Key('play_on_keep_open')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pumpAndSettle();
      expect(remote.played.single.relay?.key, 'local:1234');
    });

    testWidgets('on an iPhone the sheet says to keep the app open while it sends', (tester) async {
      await open(
        tester,
        request: local,
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
        iPhone: true,
      );
      expect(find.text('Keep Immuch360 open on this phone while the screen shows it'), findsOneWidget);
    });

    testWidgets('a relay that could not send says so', (tester) async {
      final remote = _Remote((_) => PlayOnOutcome.relayFailed);
      await open(
        tester,
        request: local,
        screens: [_screen(_tvId, 'Living room TV', PairingScreenKind.tv)],
        nearby: {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)},
        remote: remote,
      );
      await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
      await tester.pump();
      expect(find.text('Living room TV could not read it from this phone'), findsOneWidget);
    });
  });
}
