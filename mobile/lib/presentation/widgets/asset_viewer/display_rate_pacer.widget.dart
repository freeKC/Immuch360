import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

/// Asks for a frame at every refresh of the display while [active], and shows [child] as it is.
///
/// For the window of a Meta Quest while a video plays in it: the native player draws the picture in its own layer at
/// the video's rate, but the window itself presented a frame only when Flutter drew one, at each position of the
/// player. Those came at 10 a second from release 48 (Meta's review failed VRC.Quest.Performance.1), and even at each
/// 8 ms tick of the player they landed just after a refresh, so Flutter drew every other one: about 41 frames a second
/// with the controls hidden, measured on a Quest 3 on 21 November 2026. A ticker asks for the next frame from inside
/// the frame it draws, so the window follows the display (72 Hz) for the time the video plays, controls shown or not.
/// The frames are cheap: nothing is rebuilt or repainted, the last picture of the window is composed again.
///
/// Off, it asks for nothing, so a paused video or a still page lets the window rest. A route pushed over the page
/// mutes the ticker (TickerMode).
class DisplayRatePacer extends StatefulWidget {
  const DisplayRatePacer({super.key, required this.active, required this.child});

  /// Whether the window follows the display: on a Meta Quest while a video plays
  final bool active;

  final Widget child;

  @override
  State<DisplayRatePacer> createState() => _DisplayRatePacerState();
}

class _DisplayRatePacerState extends State<DisplayRatePacer> with SingleTickerProviderStateMixin {
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void didUpdateWidget(DisplayRatePacer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _apply();
    }
  }

  void _apply() {
    if (widget.active) {
      // An empty tick is enough: a running ticker schedules the next frame, and each frame is composed and presented
      final ticker = _ticker ??= createTicker(_onTick);
      if (!ticker.isActive) {
        ticker.start();
      }
    } else if (_ticker?.isActive ?? false) {
      _ticker!.stop();
    }
  }

  void _onTick(Duration elapsed) {}

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The [DisplayRatePacer] of the video of [videoPlayerProvider] ([playerKey]), on a Meta Quest only: active while the
/// video plays, or while its position advances whatever its status says, and [enabled] (the player is shown).
///
/// The position counts too because the status can lag behind the native player: after the immersive viewer gives a
/// video back, the native player plays on by itself while the status stays paused, and the window then drew about 52
/// frames a second (Quest 3, 21 November 2026). An advance keeps the pacer on for [advancingHold], longer than the
/// 100 ms between two positions, so a pause or the end lets the window rest again within half a second.
///
/// Not while the video waits: the waiting box turns at 4 frames a second so that the main thread stays free for the
/// media bridge as it fills the player again (see VideoWaitingSpinner).
class VideoDisplayRatePacer extends ConsumerStatefulWidget {
  const VideoDisplayRatePacer({super.key, required this.playerKey, this.enabled = true, required this.child});

  final String playerKey;

  /// Whether the player is on screen
  final bool enabled;

  final Widget child;

  /// How long an advance of the position keeps the window following the display
  static const advancingHold = Duration(milliseconds: 500);

  @override
  ConsumerState<VideoDisplayRatePacer> createState() => _VideoDisplayRatePacerState();
}

class _VideoDisplayRatePacerState extends ConsumerState<VideoDisplayRatePacer> {
  bool _advancing = false;
  Timer? _hold;

  void _onPosition(Duration? previous, Duration position) {
    // Forward only: a seek back is not playback
    if (previous == null || position <= previous) {
      return;
    }
    _hold?.cancel();
    _hold = Timer(VideoDisplayRatePacer.advancingHold, () {
      if (mounted) {
        setState(() => _advancing = false);
      }
    });
    if (!_advancing) {
      setState(() => _advancing = true);
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final horizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    if (!horizonOs) {
      return DisplayRatePacer(active: false, child: widget.child);
    }
    final provider = videoPlayerProvider(widget.playerKey);
    ref.listen(provider.select((s) => s.position), _onPosition);
    final status = ref.watch(provider.select((s) => s.status));
    final moving =
        status == VideoPlaybackStatus.playing ||
        (_advancing && status != VideoPlaybackStatus.buffering && status != VideoPlaybackStatus.failed);
    return DisplayRatePacer(active: widget.enabled && moving, child: widget.child);
  }
}
