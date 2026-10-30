import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_seek_series.dart';

/// The time bar of a video, in the controls of the asset viewer and of the video page of a share.
///
/// On a phone or a computer, the plain slider. With the remote control layout ([tvMode]) the bar is a stop of the
/// remote of its own, under the buttons: Down from them takes the focus there, framed by the ring of the TV shell
/// (TvFocusRing) like any other control. Left and right then move the video at each press by the step of the quick
/// series of presses of the player ([seekSeries]: 10 s, then 30 s, then 60 s, see RemoteSeekSeries), [remoteSeekStep]
/// without one, and faster while held (see [remoteSeekHoldStep], which ends the series): the video waits ([onHold])
/// until the key is released ([onRelease]). OK plays or pauses ([onToggle]) as it goes down, like a button of the
/// controls, and its press goes on to the page: held on the bar of the asset viewer it opens the details, as it does on
/// any button there. Up goes back to the buttons. The slider itself never takes the focus there, since a focused slider
/// keeps the arrows for good (Flutter issue 54984): the bar takes the keys in its place.
class VideoTimeBar extends StatefulWidget {
  const VideoTimeBar({
    super.key,
    required this.position,
    required this.duration,
    required this.tvMode,
    required this.onSeek,
    this.onHold,
    this.onRelease,
    this.onToggle,
    this.seekSeries,
  });

  final Duration position;
  final Duration duration;
  final bool tvMode;

  /// Moves the video; null while it is not loaded, which leaves the bar still
  final ValueChanged<Duration>? onSeek;

  /// A drag of the slider, or an arrow held on the bar, starts: the video waits for it
  final VoidCallback? onHold;

  /// The drag or the arrow ended: the video goes on as it was
  final VoidCallback? onRelease;

  /// OK on the bar, with the remote control layout
  final VoidCallback? onToggle;

  /// The quick series of presses of the player, with the remote control layout: the step of each press, and the hint
  /// of the controls
  final RemoteSeekSeries? seekSeries;

  @override
  State<VideoTimeBar> createState() => _VideoTimeBarState();
}

class _VideoTimeBarState extends State<VideoTimeBar> {
  /// The repeats of the arrow held, 0 while none is
  int _repeats = 0;

  /// Where the arrows took the video since the key went down: the position the player reports lags behind
  Duration? _target;

  /// The press of OK, already acted on by the bar as the key went down
  late final _okDone = <Type, Action<Intent>>{
    ActivateIntent: DoNothingAction(),
    ButtonActivateIntent: DoNothingAction(),
  };

  Duration _clamp(Duration position) {
    if (position < Duration.zero) {
      return Duration.zero;
    }
    final duration = widget.duration;
    return duration > Duration.zero && position > duration ? duration : position;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (remoteOkKeys.contains(key)) {
      // The key down and up go on to the page, whose timer of a held OK needs both (the asset viewer opens the details
      // when it is held); the select shortcut of the app then finds the bar's own action, which does nothing (see
      // build). The repeats stop here: a held key plays or pauses once.
      if (event is KeyDownEvent) {
        widget.onToggle?.call();
      }
      return event is KeyRepeatEvent ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final forward = key == LogicalKeyboardKey.arrowRight;
    if (!forward && key != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final seek = widget.onSeek;
    if (seek == null) {
      // Not loaded: the arrows stay on the bar all the same, rather than leaving the controls
      return KeyEventResult.handled;
    }
    final sign = forward ? 1 : -1;
    switch (event) {
      case KeyDownEvent():
        _repeats = 0;
        final move = widget.seekSeries?.press(forward: forward) ?? remoteSeekStep * sign;
        final target = _target = _clamp(widget.position + move);
        seek(target);
      case KeyRepeatEvent():
        if (_repeats == 0) {
          widget.onHold?.call();
          // Held, the key has its own ramp: the next press starts a new series
          widget.seekSeries?.end();
        }
        _repeats++;
        final target = _target = _clamp(
          (_target ?? widget.position) + remoteSeekHoldStep(_repeats, widget.duration) * sign,
        );
        seek(target);
      case KeyUpEvent():
        if (_repeats > 0) {
          widget.onRelease?.call();
        }
        _repeats = 0;
        _target = null;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final onSeek = widget.onSeek;
    final duration = widget.duration;
    final slider = Slider(
      value: min(widget.position.inMicroseconds.toDouble(), duration.inMicroseconds.toDouble()),
      min: 0,
      max: max(duration.inMicroseconds.toDouble(), 1),
      thumbColor: Colors.white,
      activeColor: Colors.white,
      inactiveColor: whiteOpacity75,
      padding: EdgeInsets.zero,
      onChangeStart: (_) => widget.onHold?.call(),
      onChangeEnd: (_) => widget.onRelease?.call(),
      onChanged: onSeek == null ? null : (value) => onSeek(Duration(microseconds: value.toInt())),
    );
    if (!widget.tvMode) {
      return slider;
    }
    // OK already played or paused as it went down (see _onKey): the select shortcut that it then reaches stops here
    // rather than leaving the app unhandled
    return Actions(
      actions: _okDone,
      child: Focus(
        debugLabel: 'Video time bar',
        onKeyEvent: _onKey,
        onFocusChange: (focused) {
          if (!focused && _repeats > 0) {
            // Left while held (the controls hid): the video goes on
            widget.onRelease?.call();
          }
          _repeats = 0;
          _target = null;
        },
        // Room for the focus ring around the slider
        child: Padding(
          key: const Key('video_time_bar'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          // The bar takes the keys, never the slider
          child: ExcludeFocus(child: slider),
        ),
      ),
    );
  }
}
