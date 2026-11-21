import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

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
