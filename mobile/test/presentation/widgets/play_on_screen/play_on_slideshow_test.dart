// "Slideshow on…" of a selection or an album: the sheet opens for the first item that may go, with its own title;
// once it shows on a screen, the list is kept and the slideshow runs. Nothing opens for a list with nothing to send.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/actions/play_on_slideshow.action.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

const _user = 'a1b2c3d4-0000-4000-8000-00000000abcd';
const _tvId = '0123456789abcdef';

final _tv = LinkedPeer(
  id: _tvId,
  name: 'Living room TV',
  key: Uint8List(playLinkKeyBytes),
  linkedAt: DateTime.utc(2026, 11, 10),
  kind: PairingScreenKind.tv,
);

RemoteAsset _asset(int n, {AssetVisibility visibility = AssetVisibility.timeline, int day = 1}) => RemoteAsset(
  id: '00000000-0000-4000-8000-00000000000$n',
  name: 'IMG_$n.jpg',
  ownerId: _user,
  checksum: 'c$n',
  type: AssetType.image,
  createdAt: DateTime.utc(2026, 1, day),
  updatedAt: DateTime.utc(2026),
  visibility: visibility,
  isEdited: false,
);

PlayOnRequest? _requestOf(BaseAsset asset) =>
    PlayOnRequest.ofAsset(asset, userId: _user, endpoints: const [], serverName: 'photos');

class _Screens extends LinkedPeersNotifier {
  _Screens() : super(playLinkScreensKey, maxLinkedScreens);

  @override
  Future<List<LinkedPeer>> build() async => [_tv];
}

class _Nearby extends NearbyPlayScreensNotifier {
  @override
  Map<String, PlayScreenAddress> build() => {_tvId: (host: '192.168.1.20', port: playLinkDefaultPort)};
}

class _Remote extends RemotePlaybackController {
  final played = <PlayOnRequest>[];

  @override
  RemotePlayback? build() => null;

  @override
  Future<PlayOnOutcome> play(LinkedPeer screen, PlayScreenAddress address, PlayOnRequest request) async {
    played.add(request);
    state = RemotePlayback(
      screen: screen,
      request: request,
      state: ScreenPlayState(seq: 1, phase: ScreenPlayPhase.showing, server: 'immich', itemKey: request.ratingKey),
    );
    return PlayOnOutcome.playing;
  }
}

void main() {
  setUpAll(TestUtils.init);

  late _Remote remote;
  late ProviderContainer container;
  bool? result;

  Future<void> open(WidgetTester tester, List<BaseAsset> assets) async {
    playOnPhoneScreen(tester);
    remote = _Remote();
    result = null;
    await pumpPlayOn(
      tester,
      Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await showPlayOnSlideshow(context, ref, assets),
                child: const Text('open'),
              ),
            ),
          );
        },
      ),
      overrides: [
        linkedScreensProvider.overrideWith(_Screens.new),
        nearbyPlayScreensProvider.overrideWith(_Nearby.new),
        remotePlaybackProvider.overrideWith(() => remote),
        playOnAssetRequestProvider.overrideWithValue(_requestOf),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sheet opens for the first item that may go; once it shows, the list runs as a slideshow', (
    tester,
  ) async {
    await open(tester, [_asset(1, visibility: AssetVisibility.locked), _asset(2), _asset(3)]);
    expect(find.text('Slideshow on…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('play_on_$_tvId')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(remote.played.single.ratingKey, _asset(2).id);
    expect(container.read(playOnQueueProvider)?.index, 1);
    expect(container.read(playOnQueueProvider)?.items, hasLength(3));
    expect(container.read(playOnSlideshowProvider), isTrue);
    container.read(playOnSlideshowProvider.notifier).pause();
  });

  testWidgets('a list with nothing that may go opens no sheet', (tester) async {
    await open(tester, [_asset(1, visibility: AssetVisibility.locked)]);
    expect(find.text('Slideshow on…'), findsNothing);
    expect(result, isFalse);
    expect(container.read(playOnQueueProvider), isNull);
  });

  test('a selection goes in the timeline order, the newest first', () {
    final ordered = playOnTimelineOrder([_asset(1, day: 3), _asset(2, day: 9), _asset(3, day: 5)]);
    expect(ordered.map((asset) => asset.name), ['IMG_2.jpg', 'IMG_3.jpg', 'IMG_1.jpg']);
  });
}
