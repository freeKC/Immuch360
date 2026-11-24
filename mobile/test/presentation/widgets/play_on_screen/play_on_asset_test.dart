// The asset viewer followed while a screen shows one of its photos: a swipe sends the next one 300 ms after the last
// swipe (three fast swipes send the third only), nothing goes for an asset on this phone only or a locked one, and
// nothing at all while no screen shows the viewer's asset.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

const _user = 'a1b2c3d4-0000-4000-8000-00000000abcd';

RemoteAsset _asset(int n, {AssetVisibility visibility = AssetVisibility.timeline}) => RemoteAsset(
  id: '00000000-0000-4000-8000-00000000000$n',
  name: 'IMG_$n.jpg',
  ownerId: _user,
  checksum: 'c$n',
  type: AssetType.image,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  visibility: visibility,
  isEdited: false,
);

PlayOnRequest? _requestOf(BaseAsset asset) =>
    PlayOnRequest.ofAsset(asset, userId: _user, endpoints: const [], serverName: 'photos');

class _Viewer extends AssetViewerStateNotifier {
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: _asset(1));

  void show(BaseAsset asset) => state = state.copyWith(currentAsset: asset);
}

class _Remote extends RemotePlaybackController {
  _Remote(this.initial);

  final RemotePlayback? initial;
  final sent = <PlayOnRequest>[];

  @override
  RemotePlayback? build() => initial;

  @override
  Future<PlayOnOutcome?> showNext(PlayOnRequest request) async {
    sent.add(request);
    return PlayOnOutcome.playing;
  }
}

final _screen = LinkedPeer(
  id: '0123456789abcdef',
  name: 'Living room TV',
  key: Uint8List(32),
  linkedAt: DateTime.utc(2026, 11, 24),
);

void main() {
  late _Remote remote;

  ProviderContainer containerFor(RemotePlayback? playback) {
    remote = _Remote(playback);
    final container = ProviderContainer(
      overrides: [
        assetViewerProvider.overrideWith(_Viewer.new),
        remotePlaybackProvider.overrideWith(() => remote),
        playOnAssetRequestProvider.overrideWithValue(_requestOf),
      ],
    );
    addTearDown(container.dispose);
    container.read(playOnViewerFollowProvider);
    container.read(assetViewerProvider);
    return container;
  }

  RemotePlayback showing(int n) => RemotePlayback(
    screen: _screen,
    request: _requestOf(_asset(n))!,
    state: ScreenPlayState(seq: 2, phase: ScreenPlayPhase.showing, server: 'immich', itemKey: _asset(n).id),
  );

  Future<void> wait() => Future<void>.delayed(playOnFollowDelay + const Duration(milliseconds: 150));

  test('three fast swipes: the third photo only goes to the screen', () async {
    final container = containerFor(showing(1));
    final viewer = container.read(assetViewerProvider.notifier) as _Viewer;
    viewer.show(_asset(2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    viewer.show(_asset(3));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    viewer.show(_asset(4));
    await wait();
    expect(remote.sent.map((request) => request.ratingKey), [_asset(4).id]);
  });

  test('a locked photo is never sent by a swipe', () async {
    final container = containerFor(showing(1));
    (container.read(assetViewerProvider.notifier) as _Viewer).show(_asset(2, visibility: AssetVisibility.locked));
    await wait();
    expect(remote.sent, isEmpty);
  });

  test('nothing goes while no screen shows the viewer\'s photo', () async {
    final container = containerFor(null);
    (container.read(assetViewerProvider.notifier) as _Viewer).show(_asset(2));
    await wait();
    expect(remote.sent, isEmpty);

    final other = containerFor(showing(7));
    (other.read(assetViewerProvider.notifier) as _Viewer).show(_asset(2));
    await wait();
    expect(remote.sent, isEmpty, reason: 'the screen shows another photo than the one the viewer had');
  });
}
