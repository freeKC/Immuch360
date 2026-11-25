// The asset viewer followed while a screen shows one of its photos: a swipe sends the next one 300 ms after the last
// swipe (three fast swipes send the third only), nothing goes for an asset on this phone only, a locked one, or an
// archived one the sheet did not confirm, and nothing at all while no screen shows the viewer's asset. A video that
// ended on the screen still counts as sent: the next item follows it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

const _user = 'a1b2c3d4-0000-4000-8000-00000000abcd';

RemoteAsset _asset(int n, {AssetVisibility visibility = AssetVisibility.timeline, AssetType type = AssetType.image}) =>
    RemoteAsset(
      id: '00000000-0000-4000-8000-00000000000$n',
      name: 'IMG_$n.jpg',
      ownerId: _user,
      checksum: 'c$n',
      type: type,
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

  RemotePlayback showing(int n, {AssetVisibility visibility = AssetVisibility.timeline}) => RemotePlayback(
    screen: _screen,
    request: _requestOf(_asset(n, visibility: visibility))!,
    state: ScreenPlayState(seq: 2, phase: ScreenPlayPhase.showing, server: 'immich', itemKey: _asset(n).id),
  );

  RemotePlayback video(int n, ScreenPlayPhase phase) => RemotePlayback(
    screen: _screen,
    request: _requestOf(_asset(n, type: AssetType.video))!,
    state: ScreenPlayState(seq: 3, phase: phase, server: 'immich', itemKey: _asset(n).id, media: PlayMedia.video),
  );

  final sendingState = Provider((ref) => playOnSendingState(ref));

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

  test('an archived photo is skipped unless the item sent was archived; the next swipe sends again', () async {
    final container = containerFor(showing(1));
    final viewer = container.read(assetViewerProvider.notifier) as _Viewer;
    viewer.show(_asset(2, visibility: AssetVisibility.archive));
    await wait();
    expect(remote.sent, isEmpty, reason: 'the sheet asks before an archived item, a swipe cannot');
    // Moving on from the skipped item: the screen still shows the first one, the next one goes
    viewer.show(_asset(3));
    await wait();
    expect(remote.sent.map((request) => request.ratingKey), [_asset(3).id]);

    // The user confirmed an archived item in the sheet: its archived neighbours follow
    final archived = containerFor(showing(1, visibility: AssetVisibility.archive));
    (archived.read(assetViewerProvider.notifier) as _Viewer).show(_asset(2, visibility: AssetVisibility.archive));
    await wait();
    expect(remote.sent.map((request) => request.ratingKey), [_asset(2).id]);
  });

  test('a skipped locked photo does not stop the follow', () async {
    final container = containerFor(showing(1));
    final viewer = container.read(assetViewerProvider.notifier) as _Viewer;
    viewer.show(_asset(2, visibility: AssetVisibility.locked));
    await wait();
    viewer.show(_asset(3));
    await wait();
    expect(remote.sent.map((request) => request.ratingKey), [_asset(3).id]);
  });

  test('a video that ended on the screen is still followed: the next item goes', () async {
    final container = containerFor(video(1, ScreenPlayPhase.ended));
    expect(container.read(sendingState), (sending: true, videoUnderWay: false));
    (container.read(assetViewerProvider.notifier) as _Viewer).show(_asset(2));
    await wait();
    expect(remote.sent.map((request) => request.ratingKey), [_asset(2).id]);
  });

  test('a paused video is under way: the slideshow waits; Back on the remote (idle) ends the sending', () {
    expect(containerFor(video(1, ScreenPlayPhase.paused)).read(sendingState), (sending: true, videoUnderWay: true));
    expect(containerFor(video(1, ScreenPlayPhase.playing)).read(sendingState), (sending: true, videoUnderWay: true));
    expect(containerFor(video(1, ScreenPlayPhase.idle)).read(sendingState), (sending: false, videoUnderWay: false));
    expect(containerFor(showing(1)).read(sendingState), (sending: true, videoUnderWay: false));
  });

  test('a cast of an Immich video that ended still follows; a film\'s does not', () {
    const target = CastTarget(id: 'cc', name: 'Living room', host: '192.168.1.42', port: 8009);
    CastPlayback cast(PlayOnRequest request, CastPhase phase) =>
        CastPlayback(target: target, request: request, title: '', phase: phase, at: DateTime.utc(2026));
    final clip = _requestOf(_asset(1, type: AssetType.video))!;
    expect(playOnCastFollows(cast(clip, CastPhase.ended)), isTrue);
    expect(playOnCastFollows(cast(clip, CastPhase.playing)), isTrue);
    expect(playOnCastFollows(cast(clip, CastPhase.failed)), isFalse);
    expect(playOnCastFollows(cast(clip, CastPhase.takenOver)), isFalse);
    final film = PlayOnRequest.forTarget(
      sourceId: 'plex-1',
      target: const PlexPlayTarget(server: 'abcdef0123456789', item: '77'),
      serverName: 'Plex',
    );
    expect(playOnCastFollows(cast(film, CastPhase.ended)), isFalse);
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

  group('slideshow', () {
    test('Next and Previous move the phone\'s viewer; the end of its list stops the slideshow', () async {
      final container = containerFor(showing(1));
      final jump = _Jump(count: 3);
      container.read(playOnViewerJumpProvider.notifier).state = jump;
      final slideshow = container.read(playOnSlideshowProvider.notifier);
      expect(await slideshow.step(1), isTrue);
      expect(jump.index, 1);
      expect(await slideshow.step(-1), isTrue);
      expect(jump.index, 0);
      expect(await slideshow.step(-1), isFalse, reason: 'nothing before the first');
      jump.index = 2;
      slideshow.play();
      expect(container.read(playOnSlideshowProvider), isTrue);
      expect(await slideshow.step(1), isFalse);
      slideshow.pause();
      expect(container.read(playOnSlideshowProvider), isFalse);
    });

    test(
      'a selection or an album: Next and Previous step through its list, past what may not go, to its ends',
      () async {
        final container = containerFor(showing(1));
        container.read(playOnQueueProvider.notifier).state = PlayOnQueue(
          items: [
            _asset(1),
            _asset(2, visibility: AssetVisibility.locked),
            _asset(3, visibility: AssetVisibility.archive),
            _asset(4, type: AssetType.video),
            _asset(5),
          ],
          index: 0,
        );
        final slideshow = container.read(playOnSlideshowProvider.notifier);
        expect(slideshow.canStep, isTrue);
        expect(await slideshow.step(1), isTrue);
        expect(remote.sent.map((request) => request.ratingKey), [_asset(4).id], reason: 'locked and archived skipped');
        expect(container.read(playOnQueueProvider)!.index, 3);
        expect(await slideshow.step(1), isTrue);
        expect(await slideshow.step(1), isFalse, reason: 'nothing after the last');
        expect(await slideshow.step(-1), isTrue);
        expect(remote.sent.last.ratingKey, _asset(4).id);
        expect(container.read(playOnQueueProvider)!.index, 3);
      },
    );

    test('a list whose item sent was archived sends its archived items too', () async {
      final container = containerFor(showing(1, visibility: AssetVisibility.archive));
      container.read(playOnQueueProvider.notifier).state = PlayOnQueue(
        items: [
          _asset(1, visibility: AssetVisibility.archive),
          _asset(2, visibility: AssetVisibility.archive),
        ],
        index: 0,
      );
      expect(await container.read(playOnSlideshowProvider.notifier).step(1), isTrue);
      expect(remote.sent.single.ratingKey, _asset(2).id);
    });

    test('a list while nothing shows on a screen any more: nothing goes', () async {
      final container = containerFor(null);
      container.read(playOnQueueProvider.notifier).state = PlayOnQueue(items: [_asset(1), _asset(2)], index: 0);
      expect(await container.read(playOnSlideshowProvider.notifier).step(1), isFalse);
      expect(remote.sent, isEmpty);
    });

    test('what a selection or the follow passes over', () {
      final plain = _requestOf(_asset(1));
      final archived = _requestOf(_asset(2, visibility: AssetVisibility.archive));
      expect(playOnSkips(plain, null), isFalse);
      expect(playOnSkips(null, plain), isTrue);
      expect(playOnSkips(_requestOf(_asset(3, visibility: AssetVisibility.locked)), archived), isTrue);
      expect(playOnSkips(archived, plain), isTrue);
      expect(playOnSkips(archived, archived), isFalse);
    });

    test('no viewer left on the phone: nothing moves, the slideshow stops', () async {
      final container = containerFor(showing(1));
      container.read(playOnViewerJumpProvider.notifier).state = _Jump(count: 3)..gone = true;
      final slideshow = container.read(playOnSlideshowProvider.notifier)..play();
      expect(await slideshow.step(1), isFalse);
      expect(container.read(playOnSlideshowProvider), isFalse);
    });
  });
}

/// The phone's viewer: an index in a list of [count] items
class _Jump extends AssetViewerJump {
  _Jump({required this.count});

  final int count;
  int index = 0;
  bool gone = false;

  @override
  int? get currentIndex => gone ? null : index;

  @override
  Future<void> jumpTo(int target) async {
    if (target >= 0 && target < count) {
      index = target;
    }
  }
}
