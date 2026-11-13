import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/video_link_rule.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'video_player_provider.freezed.dart';

enum VideoPlaybackStatus {
  paused,
  playing,
  buffering,
  completed,

  /// The video does not play: the native player reported an error, nothing arrived for [VideoLinkRule.deadAfter]
  /// while it waited, or, where the player tells nothing of its link, nothing played for
  /// [VideoPlayerNotifier.fallbackStallTimeout] (see [VideoPlayerNotifier.failure]). Not playing: the remote goes to the
  /// next item, play tries again (see [VideoPlayerNotifier.retry]).
  failed,
}

/// Why a video is [VideoPlaybackStatus.failed]
enum VideoFailureKind {
  /// The native player reported an error: a decoder that refused the video, a file it could not read
  error,

  /// Nothing played for [VideoPlayerNotifier.fallbackStallTimeout] while the video loaded, on a player that tells
  /// nothing of its link (iOS): the network, the server or the decoder. It clears by itself when the video plays after
  /// all.
  stalled,

  /// Nothing the server has decodes on the device (see chooseVideoSource): said before anything loads, play tries
  /// anyway (see [VideoPlayerNotifier.refuse])
  refused,

  /// The server or the share stopped sending: nothing arrived for [VideoLinkRule.deadAfter] while the video waited
  /// (see [VideoPlayerNotifier.onNativeLinkChanged]). The native player keeps trying: the bytes back clear it, and the
  /// video plays on by itself. A link that is merely slow never gets here.
  dead,
}

/// What a page tells of the link of its video while it loads or waits (see [VideoPlayerNotifier.link]): what the link
/// brings ([bitsPerSecond]) against what the video needs ([neededBitsPerSecond]), both null until measured, about how
/// long the wait still lasts ([startsIn], null when it cannot be told), whether the link has brought less than the
/// video needs for a while as it waits ([slow], see [linkIsSlow]), and whether it stopped sending ([dead])
class VideoLinkView {
  const VideoLinkView({
    required this.waiting,
    this.bitsPerSecond,
    this.neededBitsPerSecond,
    this.startsIn,
    this.slow = false,
    this.dead = false,
    this.waitedFor = Duration.zero,
    this.loading = false,
    this.framesPerSecond,
    this.neededFramesPerSecond,
  });

  final bool waiting;

  /// Whether the native player still loads media (its buffer is not full)
  final bool loading;
  final int? bitsPerSecond;
  final int? neededBitsPerSecond;
  final Duration? startsIn;
  final bool slow;
  final bool dead;

  /// How long the wait under way lasts, zero while it does not wait
  final Duration waitedFor;

  /// The link is a decoder (an AV2 video of the computers, decoded by the processor): the pictures it decodes per
  /// second against those the video needs ("Decoding: 18 of the 24 frames per second this video needs"), in place of
  /// the bits of a network
  final double? framesPerSecond;
  final double? neededFramesPerSecond;

  bool get isDecoder => neededFramesPerSecond != null;

  /// What the link brings per second against what the video consumes, null until both are measured
  double? get ratio {
    if (isDecoder) {
      final fps = framesPerSecond;
      final needed = neededFramesPerSecond!;
      return fps == null || needed <= 0 ? null : fps / needed;
    }
    final got = bitsPerSecond;
    final need = neededBitsPerSecond;
    return got == null || need == null || need <= 0 ? null : got / need;
  }

  /// Whether the loading line says the rates: both measured, while the video waits, once the wait is long enough to
  /// be noticed or the link is short
  bool get showsRates =>
      waiting &&
      ratio != null &&
      (waitedFor >= VideoPlayerNotifier.ratesAfter || ratio! < VideoLinkRule.fastRatio || dead);

  @override
  bool operator ==(Object other) =>
      other is VideoLinkView &&
      other.waiting == waiting &&
      other.bitsPerSecond == bitsPerSecond &&
      other.neededBitsPerSecond == neededBitsPerSecond &&
      other.startsIn == startsIn &&
      other.slow == slow &&
      other.dead == dead &&
      other.waitedFor == waitedFor &&
      other.loading == loading &&
      other.framesPerSecond == framesPerSecond &&
      other.neededFramesPerSecond == neededFramesPerSecond;

  @override
  int get hashCode => Object.hash(
    waiting,
    bitsPerSecond,
    neededBitsPerSecond,
    startsIn,
    slow,
    dead,
    waitedFor,
    loading,
    framesPerSecond,
    neededFramesPerSecond,
  );

  @override
  String toString() =>
      'VideoLinkView(waiting: $waiting, $bitsPerSecond of $neededBitsPerSecond bit/s, starts in $startsIn'
      '${slow ? ', slow' : ''}${dead ? ', dead' : ''})';
}

/// Why a video does not play: its [kind], the native player's own [message] for an error (technical, not translated:
/// for the logs and as the last resort of the failure panel), and the [refusal] of a video nothing decodes. For an
/// error, [refusal] is the server's copy the player could not switch to after the decoder refused the original, the
/// copy being beyond the decoders too (see runtimeFallback); null otherwise.
class VideoPlaybackFailure {
  const VideoPlaybackFailure(this.kind, [this.message, this.refusal]);

  final VideoFailureKind kind;
  final String? message;
  final VideoSourceRefusal? refusal;

  /// The error in the words of the app, when the native player sent its token (see [NativePlaybackError]); null for
  /// any other message
  NativePlaybackError? get native => NativePlaybackError.parse(message);

  @override
  bool operator ==(Object other) =>
      other is VideoPlaybackFailure && other.kind == kind && other.message == message && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(kind, message, refusal);

  @override
  String toString() => 'VideoPlaybackFailure($kind, $message${refusal != null ? ', $refusal' : ''})';
}

/// What follows where a video is for the watch progress (see VideoWatchRecorder), told by [VideoPlayerNotifier] of the
/// moves of an external player, which the state of the in-app player does not show
abstract interface class VideoPositionWatcher {
  /// An external player takes the video, which was at [position] here (see [VideoPlayerNotifier.suspendForExternalPlayer])
  void onSuspend(Duration position);

  /// An external player gave the video back at [position] (see [VideoPlayerNotifier.resumeAfterExternalPlayerAt])
  void onHandBack(Duration position);

  /// Where the video starts when it loads again after an external player that tells no position (the 360° players of
  /// the phones and of the computers): where the film was saved, 0 for the beginning
  Duration resumePositionAfterExternalPlayer();
}

@freezed
abstract class VideoPlayerState with _$VideoPlayerState {
  const factory VideoPlayerState({
    required Duration position,
    required Duration duration,
    required VideoPlaybackStatus status,
  }) = _VideoPlayerState;
}

const _defaultState = VideoPlayerState(
  position: Duration.zero,
  duration: Duration.zero,
  status: VideoPlaybackStatus.paused,
);

final videoPlayerProvider = StateNotifierProvider.autoDispose.family<VideoPlayerNotifier, VideoPlayerState, String>((
  ref,
  name,
) {
  return VideoPlayerNotifier();
});

class VideoPlayerNotifier extends StateNotifier<VideoPlayerState> {
  static final _log = Logger('VideoPlayerNotifier');

  /// Where the native player tells nothing of its link (iOS): how long a video may wait with its position still before
  /// it counts as failed. Elsewhere a wait is never a failure while bytes arrive: the link tells when nothing does
  /// (see [onNativeLinkChanged]).
  static const fallbackStallTimeout = Duration(seconds: 60);

  /// How long a wait lasts before the loading line says the rates of a link that keeps up (at once for a short one)
  static const ratesAfter = Duration(milliseconds: 1500);

  /// The clock of the link's times (how long it waited, how long it was slow), replaced by the tests
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// How long a seek waits before it goes to the native player: the moves of a slider drag in between go with it
  static const seekDelay = Duration(milliseconds: 150);

  /// How near the target of a seek a position of the native player must be to count as the seek's own, once the seek
  /// landed (see [seekTo]): a seek lands on its target, and a video that plays moves on from there
  static const seekTolerance = Duration(seconds: 1);

  /// How long after a seek landed a position of the native player far from its target is held back (a report of the
  /// player from before it, late): past it, the player's position stands, where the player stopped short of the target
  /// (its real end) or put the video elsewhere
  static const seekSettle = Duration(seconds: 2);

  VideoPlayerNotifier() : super(_defaultState);

  NativeVideoPlayerController? _controller;
  Timer? _bufferingTimer;
  Timer? _seekTimer;

  /// Where the last seek asked takes the video, from [seekTo] until the native player reports a position there after
  /// that seek landed: [state] shows it meanwhile, and the next seek of a series goes from it (see [seekBy])
  Duration? _seekTarget;

  /// The number of the last seek sent to the native player: a seek that lands after another was sent says nothing
  int _seekGeneration = 0;

  /// Whether the last seek sent landed (its call to the native player returned) and no other was asked since
  bool _seekLanded = false;

  /// Runs from the landing of the last seek for [seekSettle]
  Timer? _seekSettleTimer;

  /// Whether a drag of the time bar, or an arrow held on it, is under way: see [beginScrub]
  bool _scrubbing = false;

  /// Whether the scrub under way asked a seek that the native player did not get yet: it goes at [endScrub]
  bool _scrubSeekPending = false;
  // Runs while the status is buffering on a player that tells nothing of its link, see [fallbackStallTimeout]
  Timer? _stallTimer;

  // What the native player measured of its link since the video loaded: once it told anything, its link decides
  // whether a wait is dead, and the clock of [fallbackStallTimeout] stays off (see [onNativeLinkChanged])
  bool _linkSeen = false;
  DateTime? _slowSince;
  DateTime? _waitingSince;
  final _link = ValueNotifier<VideoLinkView?>(null);

  // Where the video loaded with [load] starts in the native player (the place a film resumes at), see [seekWhenReady]
  Duration? _loadedAt;
  VideoPlaybackFailure? _failure;
  VideoPlaybackStatus? _holdStatus;

  // Set while the video plays in an external player (the native 360° player): see [suspendForExternalPlayer]
  bool _suspended = false;

  // The video refused before it loaded, which play loads anyway: see [refuse]
  VideoSource? _refusedSource;
  VideoSource? _sourceAfterSuspension;

  // Whether the native player reported the video ready since it was last loaded
  bool _ready = false;
  // Where to take the video once it is ready again after an external player: see [resumeAfterExternalPlayerAt]
  ({Duration position, bool play})? _pendingRestore;
  // Whether [_pendingRestore] is the one of [seekWhenReady], which [cancelSeekWhenReady] may take back
  bool _pendingResume = false;
  // A restore that should have played, but came while the app was in the background: see [takePlayOnForeground]
  bool _playOnForeground = false;

  /// Whether [suspendForExternalPlayer] stopped this player
  bool get isSuspendedForExternalPlayer => _suspended;

  /// Whether the native player reported the video ready since it was last loaded
  bool get isReady => _ready;

  /// Where the video goes once the native player is ready again (after an external player, or a film that resumes,
  /// see [seekWhenReady]); null when nothing waits. Meanwhile [state] tells where the player was before it loaded, then
  /// 0 once it loaded again: this is where the video is.
  Duration? get pendingRestorePosition => _pendingRestore?.position;

  /// Follows where the video is for the watch progress, see [VideoPositionWatcher]; null when nothing does
  VideoPositionWatcher? watcher;

  final _tracksChanged = ValueNotifier(0);

  List<NativeVideoTrack> _lastTracks = const [];

  /// What [tracks] found last for the video loaded: the track menus that show again with the controls start from it,
  /// rather than without menus until the native player answers
  List<NativeVideoTrack> get lastTracks => _lastTracks;

  /// Changes when the audio and subtitle tracks of the video may have changed: a native player attached, a video
  /// loaded, a track picked (see [tracks]); what the track menus of the controls listen to
  ValueListenable<int> get tracksChanged => _tracksChanged;

  /// Why the video does not play while the status is [VideoPlaybackStatus.failed], null otherwise
  VideoPlaybackFailure? get failure => _failure;

  /// What the page tells of the link of the video, see [VideoLinkView]; null where the native player tells nothing of
  /// it, and until it does after a load
  ValueListenable<VideoLinkView?> get link => _link;

  /// Every status change goes through here: the stall check runs while the status is buffering, and a failure lasts
  /// only as long as the failed status
  @override
  @protected
  set state(VideoPlayerState value) {
    super.state = value;
    if (value.status != VideoPlaybackStatus.failed) {
      _failure = null;
    }
    if (value.status != VideoPlaybackStatus.buffering || _linkSeen) {
      _stallTimer?.cancel();
      _stallTimer = null;
    } else {
      _stallTimer ??= Timer(fallbackStallTimeout, _onStalled);
    }
  }

  @override
  void dispose() {
    _bufferingTimer?.cancel();
    _seekTimer?.cancel();
    _seekSettleTimer?.cancel();
    _stallTimer?.cancel();
    unawaited(_keepScreenOn(false));
    _controller = null;
    _tracksChanged.dispose();
    _link.dispose();

    super.dispose();
  }

  void attachController(NativeVideoPlayerController controller) {
    _controller = controller;
    _tracksChanged.value++;
  }

  /// The native player reported other tracks: a video loaded, a track picked
  void onNativeTracksChanged() {
    if (mounted) {
      _tracksChanged.value++;
    }
  }

  /// The audio and subtitle tracks of the video, their languages named in [locale] (a BCP 47 tag): none before a
  /// native player is attached, and none where the player does not list them (iOS, and the computers, which have
  /// their own audio track menu)
  Future<List<NativeVideoTrack>> tracks({String? locale}) async {
    final controller = _controller;
    if (controller == null) {
      return const [];
    }
    try {
      return _lastTracks = await controller.getTracks(locale: locale);
    } catch (e) {
      _log.warning('Error listing the tracks: $e');
      return const [];
    }
  }

  /// Plays [track], one of [tracks]
  Future<void> selectTrack(NativeVideoTrack track) async {
    try {
      if (!(await _controller?.selectTrack(track) ?? true)) {
        _log.info('The tracks changed before $track was picked');
      }
    } catch (e) {
      _log.severe('Error selecting a track: $e');
    }
  }

  /// Plays no track of [type]: subtitles off
  Future<void> disableTracks(NativeVideoTrackType type) async {
    try {
      await _controller?.disableTracks(type);
    } catch (e) {
      _log.severe('Error turning the $type tracks off: $e');
    }
  }

  /// Loads [source] in the native player, at [at] when given
  Future<void> load(VideoSource source, {Duration? at}) async {
    if (_suspended) {
      _sourceAfterSuspension = source;
      return;
    }
    _refusedSource = null;

    _ready = false;
    _playOnForeground = false;
    _lastTracks = const [];
    _forgetSeek();
    _linkSeen = false;
    _slowSince = null;
    _waitingSince = null;
    _link.value = null;
    if (state.status == VideoPlaybackStatus.failed) {
      // Loading again: the spinner, and a new stall check, from now on
      state = state.copyWith(status: VideoPlaybackStatus.buffering);
    }
    _startBufferingTimer();
    // A film that resumes loads at its place, rather than at its start and then seeks there: what the start of the film
    // took to load (its index and a second of it, 7.5 s over 2 Mbit/s) is saved. [at] wins (a retry where it stopped)
    final restore = _pendingRestore;
    final startAt = at ?? (restore != null && _pendingResume && !restore.play ? restore.position : null);
    _loadedAt = startAt != null && startAt > Duration.zero ? startAt : null;
    try {
      final controller = _controller;
      if (_loadedAt != null) {
        await controller?.loadVideoSource(source, startAt: _loadedAt);
      } else {
        await controller?.loadVideoSource(source);
      }
    } catch (e) {
      _log.severe('Error loading video source: $e');
    }
  }

  /// Loads the video again and plays it: what play does on a video that failed, a refused one included (see [refuse]).
  /// A video that stopped on its way (a dead link, a decoder that failed) loads again where it was.
  Future<void> retry() async {
    final source = _controller?.videoSource ?? _refusedSource;
    if (source == null || _suspended) {
      return;
    }
    final position = _refusedSource == null ? state.position : Duration.zero;
    await load(source, at: position > Duration.zero ? position : null);
    await play();
  }

  /// Nothing the server has decodes on the device ([refusal], see chooseVideoSource): the video fails at once without
  /// loading [source], which play loads anyway (see [retry])
  void refuse(VideoSource source, VideoSourceRefusal refusal) {
    if (!mounted) {
      return;
    }
    _refusedSource = source;
    _log.info('Refused before loading: $refusal');
    _fail(VideoPlaybackFailure(VideoFailureKind.refused, null, refusal));
  }

  /// The native player reported an error ([message]): the video fails until it is loaded again. [copyRefusal]: the
  /// server's copy is beyond the decoders too, so the player could not switch to it (the failure panel says so)
  void onNativeError(String message, {VideoSourceRefusal? copyRefusal}) {
    if (!mounted || _suspended) {
      return;
    }
    _fail(VideoPlaybackFailure(VideoFailureKind.error, message, copyRefusal));
  }

  void _onStalled() {
    _stallTimer = null;
    if (!mounted || state.status != VideoPlaybackStatus.buffering || _linkSeen) {
      return;
    }
    _log.warning(
      'Nothing played for ${fallbackStallTimeout.inSeconds} s: ${_controller?.videoSource?.path ?? 'no source'}',
    );
    _fail(const VideoPlaybackFailure(VideoFailureKind.stalled));
  }

  /// The native player measured its [link] (twice a second while it loads, see NativeVideoLink): a wait with progress
  /// is never a failure, whatever its length; a wait without progress for [VideoLinkRule.deadAfter] is a link that
  /// stopped sending ([VideoFailureKind.dead]), which bytes back clear, the native player playing on by itself; and
  /// what the page tells of the link (see [link]) follows.
  void onNativeLinkChanged(NativeVideoLink link) {
    if (!mounted || _suspended) {
      return;
    }
    _linkSeen = true;
    _stallTimer?.cancel();
    _stallTimer = null;
    final now = clock();
    final ratio = link.ratio;
    // A link that sends nothing is not a slow one, the dead link is said for it (a server silent for a minute was said
    // to send at 0 kbit/s, "it will pause now and then", 31 October 2026)
    final silent = (link.sinceProgressMs ?? 0) >= VideoLinkRule.silentAfter.inMilliseconds;
    if (silent) {
      _slowSince = null;
    } else if (ratio == null) {
      // Not measured: as it was
    } else if (ratio < VideoLinkRule.slowRatio) {
      _slowSince ??= now;
    } else {
      _slowSince = null;
    }
    if (link.waiting) {
      _waitingSince ??= now;
    } else {
      _waitingSince = null;
    }
    final dead = link.network && linkIsDead(waiting: link.waiting, sinceProgressMs: link.sinceProgressMs);
    final status = state.status;
    if (dead && status == VideoPlaybackStatus.buffering) {
      _log.warning(
        'Nothing arrived for ${VideoLinkRule.deadAfter.inSeconds} s: ${_controller?.videoSource?.path ?? 'no source'}',
      );
      _fail(const VideoPlaybackFailure(VideoFailureKind.dead));
    } else if (!dead && status == VideoPlaybackStatus.failed && _failure?.kind == VideoFailureKind.dead) {
      // The bytes are back: it waits for the native player, which plays on by itself
      _log.info('The link sends again: ${_controller?.videoSource?.path ?? 'no source'}');
      state = state.copyWith(status: link.waiting ? VideoPlaybackStatus.buffering : VideoPlaybackStatus.playing);
    } else if (link.waiting && status == VideoPlaybackStatus.playing) {
      // The native player waits for media: the spinner now, rather than after a second without a move
      state = state.copyWith(status: VideoPlaybackStatus.buffering);
    }
    final waitedFor = _waitingSince == null ? Duration.zero : now.difference(_waitingSince!);
    final remaining = link.waiting
        ? linkRemainingWaitMs(link.aheadMs, ratio, rebuffering: link.rebuffering, minimumHeldMs: link.minimumHeldMs)
        : null;
    final rate = link.bytesPerSecond;
    final need = link.neededBytesPerSecond;
    _link.value = VideoLinkView(
      waiting: link.waiting,
      bitsPerSecond: rate == null ? null : rate * 8,
      neededBitsPerSecond: need == null ? null : need * 8,
      startsIn: remaining != null && remaining >= 1000 && link.targetMs > 0 ? Duration(milliseconds: remaining) : null,
      // Said only while the video waits: a film that plays from its buffer is not paused by its link, whatever the
      // meter reads (review of 1 November 2026: a 4K film playing from a full buffer was said to "pause now and then")
      slow: link.waiting && linkIsSlow(ratio, _slowSince == null ? Duration.zero : now.difference(_slowSince!)),
      dead: dead,
      waitedFor: waitedFor,
      loading: link.loading,
      framesPerSecond: link.framesPerSecond,
      neededFramesPerSecond: link.neededFramesPerSecond,
    );
  }

  void _fail(VideoPlaybackFailure failure) {
    _bufferingTimer?.cancel();
    unawaited(_keepScreenOn(false));
    // Before the state: its listeners read the failure with the status
    _failure = failure;
    state = state.copyWith(status: VideoPlaybackStatus.failed);
  }

  Future<void> pause() async {
    _playOnForeground = false;
    if (_controller == null) {
      return;
    }

    _bufferingTimer?.cancel();

    try {
      await _controller!.pause();
      await _flushSeek();
    } catch (e) {
      _log.severe('Error pausing video: $e');
    }
  }

  Future<void> play() async {
    if (_controller == null || _suspended) {
      return;
    }
    if (state.status == VideoPlaybackStatus.failed) {
      await retry();
      return;
    }

    try {
      await _flushSeek();
      await _controller!.play();
    } catch (e) {
      _log.severe('Error playing video: $e');
    }

    _startBufferingTimer();
  }

  /// Stops the video while it plays in an external player: nothing plays behind that player, even a video that
  /// becomes ready later, and stopping, unlike pausing, frees the decoder and the buffered data for it.
  /// [play] does nothing and [load] waits until [resumeAfterExternalPlayer].
  Future<void> suspendForExternalPlayer() async {
    if (_suspended) {
      return;
    }

    // Before the stop, which takes the video back to its start. A video loaded again after another external player and
    // not ready yet is at 0 here: it is where it goes once ready
    watcher?.onSuspend(_pendingRestore?.position ?? state.position);
    _suspended = true;
    _ready = false;
    _pendingRestore = null;
    _pendingResume = false;
    _playOnForeground = false;
    _bufferingTimer?.cancel();
    _forgetSeek();

    final controller = _controller;
    _sourceAfterSuspension = controller?.videoSource;
    if (controller == null || _sourceAfterSuspension == null) {
      return;
    }

    try {
      await controller.stop();
    } catch (e) {
      _log.severe('Error stopping video: $e');
    }
  }

  /// Ends [suspendForExternalPlayer]: loads the video again, stopped at the start like a video that did not autoplay
  Future<void> resumeAfterExternalPlayer() async {
    if (!_suspended) {
      return;
    }

    _suspended = false;
    final source = _sourceAfterSuspension;
    _sourceAfterSuspension = null;
    // An external player that told no position: a film loads again where it was saved
    if (_pendingRestore == null) {
      final at = watcher?.resumePositionAfterExternalPlayer() ?? Duration.zero;
      if (at > Duration.zero) {
        _pendingRestore = (position: at, play: false);
        _pendingResume = false;
      }
    }
    if (source != null) {
      await load(source);
    }
  }

  /// Ends [suspendForExternalPlayer] after an external player that played the video on (the Spatial 2.5D player):
  /// once the video is loaded again, goes to [position], where that player stopped, and plays when [play].
  ///
  /// Coming back to the foreground also ends the suspension, see [resumeAfterExternalPlayer], and may happen before
  /// or after the external player reports where it stopped: either way, the video goes to [position] as soon as the
  /// native player reports it ready, or right away when it already did.
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async {
    watcher?.onHandBack(position);
    final restore = (position: position, play: play);
    if (_suspended) {
      _pendingRestore = restore;
      _pendingResume = false;
      await resumeAfterExternalPlayer();
      return;
    }

    if (_ready) {
      await _restore(restore);
    } else {
      _pendingRestore = restore;
      _pendingResume = false;
    }
  }

  /// Takes the video to [position] the next time the native player reports it ready, without playing it (the viewer's
  /// autoplay decides): where a film was left (see VideoWatchRecorder). Call it right before [load], whose first ready
  /// uses it up; nothing for 0. A restore already waiting, the one of an external player, wins: false then.
  bool seekWhenReady(Duration position) {
    if (_pendingRestore != null || position <= Duration.zero) {
      return false;
    }
    _pendingRestore = (position: position, play: false);
    _pendingResume = true;
    return true;
  }

  /// Takes back the position given to [seekWhenReady] while the native player is not ready yet: the video stays at its
  /// start (another file at the place of the film, see VideoWatchRecorder). False when nothing of it waits any more:
  /// the seek went, or the restore of an external player took its place.
  bool cancelSeekWhenReady() {
    if (!_pendingResume) {
      return false;
    }
    _pendingRestore = null;
    _pendingResume = false;
    // Loaded there already (see [load]): it is not at its start, the caller takes it there
    return _loadedAt == null;
  }

  Future<void> _restore(({Duration position, bool play}) restore) async {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }

    // Straight to the native player: the video came back at its start, whatever the state still says
    _seekTimer?.cancel();
    _askSeek(restore.position);
    await _sendSeek();

    if (restore.play) {
      // Same rule as the viewer's autoplay: nothing plays behind another app. The viewer plays it once the app is
      // back in the foreground, see [takePlayOnForeground].
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden) {
        _playOnForeground = true;
      } else {
        await play();
      }
    }
  }

  /// Whether a video taken back from an external player should play now that the app is in the foreground again:
  /// it was playing there, but became ready while the app was in the background, so it stayed paused. True once
  /// only, and no longer after the video is paused, toggled, loaded again or suspended meanwhile.
  bool takePlayOnForeground() {
    final play = _playOnForeground;
    _playOnForeground = false;
    return play;
  }

  /// Sends the seek waiting for its [seekDelay] at once: before the video plays or pauses
  Future<void> _flushSeek() async {
    final timer = _seekTimer;
    if (timer == null || !timer.isActive) {
      return;
    }

    timer.cancel();
    await _sendSeek();
  }

  /// Takes the video to [position]. The time shows it at once; the native player gets it [seekDelay] later, with the
  /// presses made meanwhile, or at the end of the drag of the time bar under way (see [beginScrub]).
  ///
  /// A seek takes a while in the native player (half a second on a TV emulator, longer for a stream), which goes on
  /// reporting where the video was, the seeks before under way: the reports of a quick series of presses came back
  /// in the middle of it, took the time back, and the next press went from there, so presses were lost. So until the
  /// player reports a position near the target ([seekTolerance]) after the last seek landed, the time stays on the
  /// target and each seek of a series goes from the one before (see [seekBy]); a player that stops short of the
  /// target is believed [seekSettle] after the landing.
  void seekTo(Duration position) {
    if (_controller == null || state.position == position) {
      return;
    }

    _askSeek(position);

    if (_scrubbing) {
      // The finger is still on the bar: only the time moves, the last place goes when it lifts
      _seekTimer?.cancel();
      _scrubSeekPending = true;
      return;
    }

    if (_seekTimer?.isActive ?? false) {
      return;
    }

    _seekTimer = Timer(seekDelay, () => unawaited(_sendSeek()));
  }

  /// A drag of the time bar starts, or an arrow is held on it: the video waits ([hold]), and the seeks asked until
  /// [endScrub] only move the time shown (the positions the native player reports meanwhile are held back, see
  /// [seekTo]); [endScrub] sends the last one, then the video goes on as it was. One seek per gesture: the seek every
  /// [seekDelay] of the drag sent the native player to each place the finger crossed, a new range request each to the
  /// share or the server while the reads of the places before still came in (S24 and a Plex film, 13 November 2026:
  /// 5 seeks in the 0.55 s of a drag, the picture back 5 s later, tens of seconds after a slower drag).
  void beginScrub() {
    _scrubbing = true;
    hold();
  }

  /// The drag of the time bar, or the arrow held, ended: the native player gets the last place asked, then the video
  /// goes on as it was before [beginScrub]
  void endScrub() {
    if (!_scrubbing) {
      return;
    }
    _scrubbing = false;
    unawaited(_endScrub());
  }

  Future<void> _endScrub() async {
    if (_scrubSeekPending) {
      await _sendSeek();
    }
    if (mounted) {
      release();
    }
  }

  /// [position] becomes the target of the seek under way, shown at once
  void _askSeek(Duration position) {
    _seekTarget = position;
    _seekLanded = false;
    _seekSettleTimer?.cancel();
    _seekSettleTimer = null;
    state = state.copyWith(position: position);
  }

  /// Sends the target of the seek under way to the native player, and waits for it to land there
  Future<void> _sendSeek() async {
    final controller = _controller;
    final target = _seekTarget;
    // What is sent goes to the target: the seek a scrub asked is on its way too
    _scrubSeekPending = false;
    if (controller == null || target == null) {
      return;
    }

    final generation = ++_seekGeneration;
    try {
      await controller.seekTo(target.inMilliseconds);
    } catch (e) {
      _log.severe('Error seeking video: $e');
    }

    // Another seek was asked or sent meanwhile: its own landing counts
    if (!mounted ||
        generation != _seekGeneration ||
        _seekTarget != target ||
        (_seekTimer?.isActive ?? false) ||
        _scrubSeekPending) {
      return;
    }

    _seekLanded = true;
    _seekSettleTimer = Timer(seekSettle, _onSeekSettled);
    // The player may already be there: a paused video tells it no more
    final position = _controller?.playbackInfo?.position;
    if (position != null) {
      _takesPlayerPosition(Duration(milliseconds: position));
    }
  }

  /// Whether the native player's [position] may be shown: always without a seek under way; with one, only once it
  /// landed and near its target, which ends it
  bool _takesPlayerPosition(Duration position) {
    final target = _seekTarget;
    if (target == null) {
      return true;
    }
    if (!_seekLanded || (position - target).abs() > seekTolerance) {
      return false;
    }

    _forgetSeek();
    return true;
  }

  /// [seekSettle] after the landing, the player never came near the target: where it is stands
  void _onSeekSettled() {
    _seekSettleTimer = null;
    if (!mounted || _seekTarget == null || !_seekLanded) {
      return;
    }

    _forgetSeek();
    final position = _controller?.playbackInfo?.position;
    if (position != null) {
      state = state.copyWith(position: Duration(milliseconds: position));
    }
  }

  /// No seek under way any more: a new video, the player handed to another one, or the player got there
  void _forgetSeek() {
    _seekTimer?.cancel();
    _scrubSeekPending = false;
    _seekSettleTimer?.cancel();
    _seekSettleTimer = null;
    _seekTarget = null;
    _seekLanded = false;
    _seekGeneration++;
  }

  /// Seeks [delta] from where the video is, or from where the seek under way takes it: not before its start, nor past
  /// its end once its duration is known
  void seekBy(Duration delta) {
    var target = (_seekTarget ?? state.position) + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (state.duration > Duration.zero && target > state.duration) {
      target = state.duration;
    }
    seekTo(target);
  }

  void toggle() {
    _holdStatus = null;
    _playOnForeground = false;

    switch (state.status) {
      case VideoPlaybackStatus.paused:
        unawaited(play());
      case VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering:
        unawaited(pause());
      case VideoPlaybackStatus.completed:
        unawaited(restart());
      case VideoPlaybackStatus.failed:
        unawaited(retry());
    }
  }

  /// Pauses playback and preserves the current status for later restoration.
  void hold() {
    if (_holdStatus != null) {
      return;
    }

    _holdStatus = state.status;
    unawaited(pause());
  }

  /// Restores playback to the status before [hold] was called.
  void release() {
    final status = _holdStatus;
    _holdStatus = null;

    switch (status) {
      case VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering:
        unawaited(play());
      default:
    }
  }

  Future<void> restart() async {
    seekTo(Duration.zero);
    await play();
  }

  Future<void> setVolume(double volume) async {
    try {
      await _controller?.setVolume(volume);
    } catch (e) {
      _log.severe('Error setting volume: $e');
    }
  }

  Future<void> setLoop(bool loop) async {
    try {
      await _controller?.setLoop(loop);
    } catch (e) {
      _log.severe('Error setting loop: $e');
    }
  }

  void onNativePlaybackReady() {
    if (!mounted) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    final videoInfo = _controller?.videoInfo;

    if (playbackInfo == null || videoInfo == null) {
      return;
    }

    final position = Duration(milliseconds: playbackInfo.position);
    var status = _mapStatus(playbackInfo.status);
    if (playbackInfo.status == PlaybackStatus.stopped && state.status != VideoPlaybackStatus.completed) {
      // Never played yet, not completed = we show the resume button instead of the replay button
      status = VideoPlaybackStatus.paused;
    }

    if (status != VideoPlaybackStatus.playing) {
      // No playback = no loading indicator needed
      _bufferingTimer?.cancel();
    }

    state = state.copyWith(
      // Media3 is ready again after each seek: the ready of a seek before the last one tells an old position
      position: _takesPlayerPosition(position) ? position : state.position,
      duration: Duration(milliseconds: videoInfo.duration),
      // A player in error stays failed until it is loaded again; a stall ends here
      status: _failedOnError ? VideoPlaybackStatus.failed : status,
    );

    _ready = true;
    final restore = _pendingRestore;
    if (restore != null) {
      _pendingRestore = null;
      _pendingResume = false;
      final loadedAt = _loadedAt;
      // Loaded at its place (see [load]): no seek, unless the platform started it elsewhere (iOS starts at 0)
      if (loadedAt == null || loadedAt != restore.position || (position - loadedAt).abs() > seekTolerance) {
        unawaited(_restore(restore));
      }
    }
  }

  void onNativePositionChanged() {
    if (!mounted) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    if (playbackInfo == null) {
      return;
    }

    final position = Duration(milliseconds: playbackInfo.position);
    // A seek under way: where the video was, or a seek before it (see [seekTo])
    if (!_takesPlayerPosition(position) || state.position == position) {
      return;
    }

    if (state.status == VideoPlaybackStatus.playing) {
      _startBufferingTimer();
    }

    // It moves: the buffering, or the stall, is over
    final moving =
        state.status == VideoPlaybackStatus.buffering ||
        (state.status == VideoPlaybackStatus.failed && !_failedOnError);
    state = state.copyWith(position: position, status: moving ? VideoPlaybackStatus.playing : state.status);
  }

  void onNativeStatusChanged() {
    // The plugin reports the status of its own calls (play, pause, stop), which do not lift an error
    if (!mounted || _failedOnError) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    if (playbackInfo == null) {
      return;
    }

    final newStatus = _mapStatus(playbackInfo.status);
    switch (newStatus) {
      case VideoPlaybackStatus.playing:
        unawaited(_keepScreenOn(true));
        _startBufferingTimer();
      default:
        onNativePlaybackEnded();
    }

    if (state.status != newStatus) {
      state = state.copyWith(status: newStatus);
    }
  }

  void onNativePlaybackEnded() {
    unawaited(_keepScreenOn(false));
    _bufferingTimer?.cancel();
  }

  /// What keeps the screen on, replaced by the tests
  @visibleForTesting
  static Future<void> Function(bool on) toggleWakelock = (on) => WakelockPlus.toggle(enable: on);

  /// Keeps the screen on while the video plays, or lets it go. A Linux session without the screen saver service that
  /// wakelock_plus asks (org.freedesktop.ScreenSaver: a bare window manager, WSLg, a CI virtual screen) refuses it: the
  /// video plays all the same, without an unhandled error per video
  static Future<void> _keepScreenOn(bool on) async {
    try {
      await toggleWakelock(on);
    } catch (error) {
      _log.fine('The screen cannot be kept on: $error');
    }
  }

  void _startBufferingTimer() {
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && state.status != VideoPlaybackStatus.completed && state.status != VideoPlaybackStatus.failed) {
        state = state.copyWith(status: VideoPlaybackStatus.buffering);
      }
    });
  }

  bool get _failedOnError => _failure?.kind == VideoFailureKind.error;

  static VideoPlaybackStatus _mapStatus(PlaybackStatus status) => switch (status) {
    PlaybackStatus.playing => VideoPlaybackStatus.playing,
    PlaybackStatus.paused => VideoPlaybackStatus.paused,
    PlaybackStatus.stopped => VideoPlaybackStatus.completed,
  };
}
