// "Play on..." of a photo or a video of the Immich library (release 52): the request of the asset the viewer shows
// (its id, the phone's account and hashes of its server's addresses, never a session), the sheet, and the viewer followed
// while a screen or a Cast device shows one of its assets: a swipe to the next photo sends that one, 300 ms after
// the last swipe, so that three fast swipes send the last photo only.
//
// The slideshow the phone steers: Previous and Next of the dock move the phone's viewer (the album, the search, the
// timeline it was opened on), whose move sends the photo; Slideshow moves it every few seconds, waiting for a video
// to end on the screen (a paused one included). A video that ended there still counts as sent: the next item goes.
// It stops at the end of the viewer's list, once nothing is sent any more (Stop, Back on the remote, the screen
// gone), or when the viewer closes on the phone.
//
// The viewer followed never sends a locked item, nor an archived one unless the item sent before was archived too
// (the sheet asked before that one): an item skipped stays on the phone, the screen keeps the one before, and the
// next move sends again.
//
// A selection of the timeline, or an album, goes as a slideshow without the viewer (release 53): "Slideshow on…"
// sends its first item that may go, then the same Previous, Slideshow and Next step through the list the phone
// keeps ([playOnQueueProvider]), with the same rules for locked and archived items. The phone's clock drives it: the
// app stays open on the phone meanwhile.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
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
      projection: ref.read(playOnProjectionProvider)(asset),
    );
  };
});

/// The hint a play gives of how [asset] is laid out, for the screen's matching viewer: a whole sphere when this phone
/// views it as 360° (its exif, the user's "View as 360°", the scan of the device) or it is the raw file of a 360°
/// camera, which the screen's 360° viewers stitch; else flat. The screen still checks it has a 360° view for it.
final playOnProjectionProvider = Provider<PlayProjection Function(BaseAsset asset)>((ref) {
  return (asset) => ref.read(isEquirectangularProvider(asset)) || ref.read(rawMediaKindProvider(asset)) != null
      ? PlayProjection.equirect
      : PlayProjection.flat;
});

/// Opens the "Play on..." sheet for [asset]; false when it has no request (on this device only). The viewer it is
/// opened from becomes the one the slideshow moves.
Future<bool> showPlayOnSheetForAsset(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  final request = ref.read(playOnAssetRequestProvider)(asset);
  if (request == null) {
    return false;
  }
  ref.read(playOnViewerJumpProvider.notifier).state = ref.read(assetViewerJumpProvider);
  ref.read(playOnQueueProvider.notifier).state = null;
  return showPlayOnSheet(context, request);
}

/// Whether the follow or the slideshow passes over [request] rather than send it, while [sent] is on the screen: an
/// item on this phone only, a locked one, an archived one unless [sent] was archived too (the sheet asked for that one)
bool playOnSkips(PlayOnRequest? request, PlayOnRequest? sent) {
  final private = request?.immich;
  return request == null ||
      private == null ||
      private.locked ||
      (private.archived && !(sent?.immich?.archived ?? false));
}

/// The most items a selection or an album sends as a slideshow
const playOnQueueMax = 1000;

/// The list a slideshow of a selection or an album steps through, and where it is
@immutable
class PlayOnQueue {
  const PlayOnQueue({required this.items, required this.index});

  final List<BaseAsset> items;
  final int index;

  PlayOnQueue at(int index) => PlayOnQueue(items: items, index: index);
}

/// The slideshow of a selection or an album the phone steps through; null while the viewer is the list
final playOnQueueProvider = StateProvider<PlayOnQueue?>((_) => null);

/// "Slideshow on…" of [assets] (a selection, an album, in that order, [playOnQueueMax] at most): the sheet for the
/// first one that may go, then the slideshow runs once it shows on a screen or a Cast device. False when nothing
/// went: none may go (all on this phone only, or locked), or the user chose nothing.
Future<bool> showPlayOnSlideshow(BuildContext context, WidgetRef ref, List<BaseAsset> assets) async {
  final requestOf = ref.read(playOnAssetRequestProvider);
  final items = assets.take(playOnQueueMax).toList(growable: false);
  final first = items.indexWhere((asset) => !playOnSkips(requestOf(asset), null) || _archivedOnly(requestOf(asset)));
  if (first < 0) {
    return false;
  }
  final request = requestOf(items[first])!;
  final playing = await showPlayOnSheet(context, request, title: context.t.play_on_slideshow);
  if (!playing) {
    return false;
  }
  ref.read(playOnViewerJumpProvider.notifier).state = null;
  ref.read(playOnQueueProvider.notifier).state = PlayOnQueue(items: items, index: first);
  ref.read(playOnSlideshowProvider.notifier).play();
  return true;
}

/// An archived item the sheet asks for: it may open a slideshow
bool _archivedOnly(PlayOnRequest? request) {
  final private = request?.immich;
  return private != null && !private.locked && private.archived;
}

/// "Slideshow on…" of an album: its items, [playOnQueueMax] at most, in the album's order
Future<bool> showPlayOnSlideshowOfTimeline(BuildContext context, WidgetRef ref, TimelineService timeline) async {
  final count = timeline.totalAssets < playOnQueueMax ? timeline.totalAssets : playOnQueueMax;
  if (count == 0) {
    return false;
  }
  final assets = await timeline.loadAssets(0, count);
  if (!context.mounted) {
    return false;
  }
  return showPlayOnSlideshow(context, ref, assets);
}

/// The viewer the last "Play on..." of an asset was opened from: its moves are the slideshow's steps
final playOnViewerJumpProvider = StateProvider<AssetViewerJump?>((_) => null);

/// Whether [remote] shows an item of the phone's viewer: under way, or an Immich video that ended there (the next item
/// of the viewer may follow it)
bool playOnRemoteFollows(RemotePlayback? remote) =>
    remote != null &&
    !remote.lost &&
    (!remote.ended || (remote.state.phase == ScreenPlayPhase.ended && remote.request.sourceId == playOnImmichSource));

/// The same for a cast
bool playOnCastFollows(CastPlayback? cast) =>
    cast != null && cast.request.sourceId == playOnImmichSource && (cast.live || cast.phase == CastPhase.ended);

/// Whether a screen or a Cast device shows an item of this phone now, and whether that item is a video under way
({bool sending, bool videoUnderWay}) playOnSendingState(Ref ref) {
  final remote = ref.read(remotePlaybackProvider);
  final cast = ref.read(castPlaybackProvider);
  if (playOnRemoteFollows(remote)) {
    final phase = remote!.state.phase;
    final video = remote.state.media == PlayMedia.video || (remote.state.media == null && !remote.request.isPhoto);
    return (
      sending: true,
      videoUnderWay:
          video &&
          (phase == ScreenPlayPhase.opening ||
              phase == ScreenPlayPhase.playing ||
              phase == ScreenPlayPhase.paused ||
              phase == ScreenPlayPhase.buffering ||
              phase == ScreenPlayPhase.asking),
    );
  }
  if (playOnCastFollows(cast)) {
    return (sending: true, videoUnderWay: !cast!.request.isPhoto && cast.live && cast.phase != CastPhase.showing);
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

  /// Whether the phone's viewer, or the list of a selection or an album, is there to move
  bool get canStep => ref.read(playOnQueueProvider) != null || ref.read(playOnViewerJumpProvider)?.currentIndex != null;

  /// Moves the phone's viewer by [delta], or the list of a selection or an album; false when it could not (the end of
  /// its list, or no viewer)
  Future<bool> step(int delta) async {
    final queue = ref.read(playOnQueueProvider);
    if (queue != null) {
      return _stepQueue(queue, delta);
    }
    final jump = ref.read(playOnViewerJumpProvider);
    final index = jump?.currentIndex;
    if (jump == null || index == null) {
      pause();
      return false;
    }
    await jump.jumpTo(index + delta);
    return jump.currentIndex != index;
  }

  /// The next item of the list that may go, [delta] away (one by one past those skipped), sent where the item before
  /// shows; false at the end of the list, or once nothing shows any more
  Future<bool> _stepQueue(PlayOnQueue queue, int delta) async {
    if (!playOnSendingState(ref).sending || delta == 0) {
      return false;
    }
    final remote = ref.read(remotePlaybackProvider);
    final toScreen = playOnRemoteFollows(remote);
    final sent = toScreen ? remote!.request : ref.read(castPlaybackProvider)?.request;
    final requestOf = ref.read(playOnAssetRequestProvider);
    for (var index = queue.index + delta.sign; index >= 0 && index < queue.items.length; index += delta.sign) {
      final request = requestOf(queue.items[index]);
      if (playOnSkips(request, sent)) {
        continue;
      }
      ref.read(playOnQueueProvider.notifier).state = queue.at(index);
      _log.info('Play on: the slideshow of a list moves on');
      if (toScreen) {
        await ref.read(remotePlaybackProvider.notifier).showNext(request!);
      } else {
        await ref.read(castPlaybackProvider.notifier).castNext(request!);
      }
      return true;
    }
    return false;
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
  // The last item the follow did not send (locked, archived, on this phone only): moving on from it still follows
  String? skipped;
  ref.onDispose(() => timer?.cancel());
  ref.listen(assetViewerProvider.select((state) => state.currentAsset), (previous, next) {
    final before = previous?.remoteId;
    if (next == null || before == null || next.remoteId == before) {
      return;
    }
    final remote = ref.read(remotePlaybackProvider);
    final cast = ref.read(castPlaybackProvider);
    // The photo before is the one the screen shows, or one swiped past while the next was waiting to go, or one the
    // follow skipped
    final waiting = (timer?.isActive ?? false) || before == skipped;
    final screenShows = playOnRemoteFollows(remote) && (remote!.isOfAsset(before) || waiting);
    final castShows =
        !screenShows && playOnCastFollows(cast) && (cast!.request.ratingKey == before.toLowerCase() || waiting);
    if (!screenShows && !castShows) {
      skipped = null;
      return;
    }
    timer?.cancel();
    timer = Timer(playOnFollowDelay, () {
      final request = ref.read(playOnAssetRequestProvider)(next);
      final sent = screenShows ? ref.read(remotePlaybackProvider)?.request : ref.read(castPlaybackProvider)?.request;
      // On this phone only, locked, or archived while the item sent was not (the sheet asks before an archived item):
      // the screen keeps the one before
      if (playOnSkips(request, sent)) {
        skipped = next.remoteId;
        _log.info('Play on: the viewer moved to an item that is not sent');
        return;
      }
      skipped = null;
      _log.info('Play on: the viewer moved, the next item goes');
      if (screenShows) {
        unawaited(ref.read(remotePlaybackProvider.notifier).showNext(request!));
      } else {
        unawaited(ref.read(castPlaybackProvider.notifier).castNext(request!));
      }
    });
  });
});

/// Previous, Slideshow or Pause, Next of the dock, while a screen or a Cast device shows an item of the phone's viewer
class PlayOnSlideshowButtons extends ConsumerWidget {
  const PlayOnSlideshowButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(playOnViewerJumpProvider) == null && ref.watch(playOnQueueProvider) == null) {
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
