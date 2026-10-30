// The accelerated seek of a video on a TV: a quick series of left or right presses moves the video further at each
// press, and the controls show the step of the last one (VideoSeekHint).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// How far the presses of a quick series move a video on a TV: 10 s, then 30 s, then 60 s for every press after
const remoteSeekSeriesSteps = [Duration(seconds: 10), Duration(seconds: 30), Duration(seconds: 60)];

/// How long after a press the next one still belongs to its series: past it, the next press moves 10 s again
const remoteSeekSeriesWindow = Duration(milliseconds: 1500);

/// The step of the press [count] of a series, from 1
Duration remoteSeekSeriesStep(int count) =>
    remoteSeekSeriesSteps[(count - 1).clamp(0, remoteSeekSeriesSteps.length - 1)];

/// What the hint of a series shows: the way and the step of its last press
typedef RemoteSeekHint = ({bool forward, Duration step});

/// The quick series of left or right presses on a video with the remote control layout: where left and right seek (the
/// time bar of the controls, a video alone in the viewer, a file of a share opened without its folder), each press
/// moves the video by [press]. The first press moves 10 s, the next ones of the series 30 s then 60 s (see
/// [remoteSeekSeriesSteps]); the series ends [remoteSeekSeriesWindow] after its last press, at a press the other way,
/// or when a key is held (which has its own ramp). Listeners hear each press and the end, for the hint ([hint]).
class RemoteSeekSeries extends ChangeNotifier {
  /// The presses of the series under way, 0 between series
  int _count = 0;
  bool _forward = true;
  Timer? _end;

  /// The last press of the series under way, null between series
  RemoteSeekHint? get hint => _count == 0 ? null : (forward: _forward, step: remoteSeekSeriesStep(_count));

  /// A press of right ([forward]) or left: how far it moves the video, negative backward
  Duration press({required bool forward}) {
    if (forward != _forward) {
      _count = 0;
    }
    _count++;
    _forward = forward;
    _end?.cancel();
    _end = Timer(remoteSeekSeriesWindow, end);
    notifyListeners();
    final step = remoteSeekSeriesStep(_count);
    return forward ? step : -step;
  }

  /// Ends the series under way at once: the next press moves 10 s
  void end() {
    _end?.cancel();
    _end = null;
    if (_count != 0) {
      _count = 0;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _end?.cancel();
    super.dispose();
  }
}

/// The series of the player under a key (an asset id, the key of a video of a network share), one for the viewer or
/// the page, which takes left and right while it has the focus, and for its controls, whose time bar takes them below
/// the buttons and which show the hint. It stays while a series runs, even when nobody watches it: the page reads it
/// as a key comes, before its controls show.
final remoteSeekSeriesProvider = Provider.autoDispose.family<RemoteSeekSeries, String>((ref, key) {
  final series = RemoteSeekSeries();
  KeepAliveLink? running;
  void onChange() {
    if (series.hint != null) {
      running ??= ref.keepAlive();
    } else {
      running?.close();
      running = null;
    }
  }

  series.addListener(onChange);
  ref.onDispose(() {
    series.removeListener(onChange);
    series.dispose();
  });
  return series;
});

/// The hint of a series in the controls of a video on a TV: the way of the last press, as the fast forward and rewind
/// icons, and its step ("30 s"), while the series runs; nothing between series
class VideoSeekHint extends StatelessWidget {
  const VideoSeekHint({super.key, required this.series, this.shadows});

  final RemoteSeekSeries series;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: series,
      builder: (context, _) {
        final hint = series.hint;
        if (hint == null) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          child: Row(
            key: const Key('video_seek_hint'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hint.forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                color: Colors.white,
                size: 20,
                shadows: shadows,
              ),
              const SizedBox(width: 4),
              Text(
                context.t.tv_video_seek_step(seconds: hint.step.inSeconds),
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  shadows: shadows,
                ),
              ),
              // Room before the time of the video, which follows it
              const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }
}
