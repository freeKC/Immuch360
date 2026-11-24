// "Play on..." of a photo or a video of the Immich library (release 52): the request of the asset the viewer shows
// (its id, the phone's account and the addresses of its server, never a session), the sheet, and the viewer followed
// while a screen or a Cast device shows one of its assets: a swipe to the next photo sends that one, 300 ms after
// the last swipe, so that three fast swipes send the last photo only.
//
// The slideshow the phone steers: Previous and Next of the dock move the phone's viewer (the album, the search, the
// timeline it was opened on), whose move sends the photo; Slideshow moves it every few seconds, waiting for a video
// to end on the screen. It stops at the end of the viewer's list, once nothing is sent any more, or when the viewer
// closes on the phone.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhonePlay');

/// The request of an asset of this phone's Immich server: null for an asset on this device only, or with no server
final playOnAssetRequestProvider = Provider<PlayOnRequest? Function(BaseAsset asset)>((ref) {
  return (asset) {
    final user = ref.read(currentUserProvider);
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (user == null || endpoint == null || endpoint.isEmpty) {
      return null;
    }
    final host = Uri.tryParse(endpoint)?.host;
    return PlayOnRequest.ofAsset(
      asset,
      userId: user.id,
      endpoints: ApiService.getServerUrls(),
      serverName: host == null || host.isEmpty ? endpoint : host,
    );
  };
});

/// Opens the "Play on..." sheet for [asset]; false when it has no request (on this device only). The viewer it is
/// opened from becomes the one the slideshow moves.
Future<bool> showPlayOnSheetForAsset(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  final request = ref.read(playOnAssetRequestProvider)(asset);
  if (request == null) {
    return false;
  }
  ref.read(playOnViewerJumpProvider.notifier).state = ref.read(assetViewerJumpProvider);
  return showPlayOnSheet(context, request);
}

/// The viewer the last "Play on..." of an asset was opened from: its moves are the slideshow's steps
final playOnViewerJumpProvider = StateProvider<AssetViewerJump?>((_) => null);

/// Whether a screen or a Cast device shows an item of this phone now, and whether that item is a video under way
({bool sending, bool videoUnderWay}) playOnSendingState(Ref ref) {
  final remote = ref.read(remotePlaybackProvider);
  final cast = ref.read(castPlaybackProvider);
  if (remote != null && !remote.lost && !remote.ended) {
    final phase = remote.state.phase;
    final video = remote.state.media == PlayMedia.video || (remote.state.media == null && !remote.request.isPhoto);
    return (
      sending: true,
      videoUnderWay:
          video &&
          (phase == ScreenPlayPhase.opening ||
              phase == ScreenPlayPhase.playing ||
              phase == ScreenPlayPhase.buffering ||
              phase == ScreenPlayPhase.asking),
    );
  }
  if (cast != null && cast.live) {
    return (
      sending: true,
      videoUnderWay: !cast.request.isPhoto && cast.phase != CastPhase.paused && cast.phase != CastPhase.showing,
    );
  }
  return (sending: false, videoUnderWay: false);
}

/// See the top of this file: true while the slideshow runs
class PlayOnSlideshowController extends Notifier<bool> {
  Timer? _timer;

  /// How long a photo stays before the next one
  static const interval = Duration(seconds: 6);

  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    return false;
  }

  /// Whether the phone's viewer is there to move
  bool get canStep => ref.read(playOnViewerJumpProvider)?.currentIndex != null;

  /// Moves the phone's viewer by [delta]; false when it could not (the end of its list, or no viewer)
  Future<bool> step(int delta) async {
    final jump = ref.read(playOnViewerJumpProvider);
    final index = jump?.currentIndex;
    if (jump == null || index == null) {
      pause();
      return false;
    }
    await jump.jumpTo(index + delta);
    return jump.currentIndex != index;
  }

  void play() {
    _timer?.cancel();
    state = true;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    state = false;
  }

  Future<void> _tick() async {
    final sending = playOnSendingState(ref);
    if (!sending.sending) {
      return pause();
    }
    // A video plays to its end before the next item
    if (sending.videoUnderWay) {
      return;
    }
    if (!await step(1)) {
      pause();
    }
  }
}

final playOnSlideshowProvider = NotifierProvider<PlayOnSlideshowController, bool>(PlayOnSlideshowController.new);

/// How long after the last swipe the viewer's asset is sent
const playOnFollowDelay = Duration(milliseconds: 300);

/// Follows the asset viewer while a screen or a Cast device shows one of its assets; watched by the dock, which lives
/// as long as the app
final playOnViewerFollowProvider = Provider<void>((ref) {
  Timer? timer;
  ref.onDispose(() => timer?.cancel());
  ref.listen(assetViewerProvider.select((state) => state.currentAsset), (previous, next) {
    final before = previous?.remoteId;
    if (next == null || before == null || next.remoteId == before) {
      return;
    }
    final remote = ref.read(remotePlaybackProvider);
    final cast = ref.read(castPlaybackProvider);
    // The photo before is the one the screen shows, or one swiped past while the next was waiting to go
    final waiting = timer?.isActive ?? false;
    final screenShows = remote != null && !remote.lost && !remote.ended && (remote.isOfAsset(before) || waiting);
    final castShows =
        !screenShows &&
        cast != null &&
        cast.live &&
        cast.request.sourceId == playOnImmichSource &&
        (cast.request.ratingKey == before.toLowerCase() || waiting);
    if (!screenShows && !castShows) {
      return;
    }
    timer?.cancel();
    timer = Timer(playOnFollowDelay, () {
      final request = ref.read(playOnAssetRequestProvider)(next);
      if (request == null) {
        // On this phone only: the screen keeps the one before
        return;
      }
      if (request.immich?.locked ?? false) {
        return;
      }
      _log.info('Play on: the viewer moved, the next item goes');
      if (screenShows) {
        unawaited(ref.read(remotePlaybackProvider.notifier).showNext(request));
      } else {
        unawaited(ref.read(castPlaybackProvider.notifier).castNext(request));
      }
    });
  });
});

/// Previous, Slideshow or Pause, Next of the dock, while a screen or a Cast device shows an item of the phone's viewer
class PlayOnSlideshowButtons extends ConsumerWidget {
  const PlayOnSlideshowButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(playOnViewerJumpProvider) == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final running = ref.watch(playOnSlideshowProvider);
    final slideshow = ref.read(playOnSlideshowProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('play_on_previous'),
          icon: Icon(Icons.skip_previous_rounded, semanticLabel: t.play_bar_previous),
          onPressed: () => unawaited(slideshow.step(-1)),
        ),
        IconButton(
          key: const Key('play_on_slideshow'),
          icon: Icon(
            running ? Icons.pause_circle_outline_rounded : Icons.slideshow_rounded,
            semanticLabel: running ? t.play_bar_slideshow_pause : t.play_bar_slideshow,
          ),
          onPressed: running ? slideshow.pause : slideshow.play,
        ),
        IconButton(
          key: const Key('play_on_next'),
          icon: Icon(Icons.skip_next_rounded, semanticLabel: t.play_bar_next),
          onPressed: () => unawaited(slideshow.step(1)),
        ),
      ],
    );
  }
}
