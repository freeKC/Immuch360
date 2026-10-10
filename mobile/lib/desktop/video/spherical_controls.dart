// The controls of the 360° player of the computers (design 2.6 and 4.3): close, title, 360 or 180 degrees, the 3D
// layout, the audio track, full screen at the top; the buffering with its percentage in the middle; play, 10 s back and
// forward, the time bar and mute at the bottom.
//
// When they show (SphericalControlsVisibility): on a mouse move or a key, for 3 s, and the cursor hides with them; all
// the time while the video does not play (paused, loading, ended), while the pointer is over them and while one of them
// has the keyboard focus, so that a control reached with Tab never disappears under the user. A drag of the view hides
// them, as it moves the picture under them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Whether the controls and the cursor show, see the top of this file
class SphericalControlsVisibility extends ChangeNotifier {
  SphericalControlsVisibility({this.hideDelay = const Duration(seconds: 3)});

  /// Without a move or a key for this long, the controls hide while the video plays
  final Duration hideDelay;

  bool _playing = false;
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;
  bool _active = true;
  Timer? _timer;
  bool _disposed = false;

  /// Whether the controls show
  bool get visible => !_dragging && (_active || !_playing || _hovered || _focused);

  /// Whether the mouse cursor hides over the video: while the controls are hidden
  bool get cursorHidden => !visible;

  /// The pointer moved over the player, or a key was used: the controls show for [hideDelay]
  void activity() {
    _active = true;
    _restartTimer();
    _changed();
  }

  /// A click on the view that was not a drag: the controls show, or hide when they showed
  void toggle() {
    if (visible && _playing && !_hovered && !_focused) {
      _active = false;
      _timer?.cancel();
    } else {
      _active = true;
      _restartTimer();
    }
    _changed();
  }

  void dragStarted() {
    _dragging = true;
    _active = false;
    _timer?.cancel();
    _changed();
  }

  void dragEnded() {
    _dragging = false;
    _changed();
  }

  set playing(bool playing) {
    if (playing == _playing) {
      return;
    }
    _playing = playing;
    if (playing) {
      // The controls that showed while paused stay a moment, then go
      _active = true;
      _restartTimer();
    }
    _changed();
  }

  set hovered(bool hovered) {
    if (hovered == _hovered) {
      return;
    }
    _hovered = hovered;
    if (!hovered) {
      _active = true;
      _restartTimer();
    }
    _changed();
  }

  set focused(bool focused) {
    if (focused == _focused) {
      return;
    }
    _focused = focused;
    _changed();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(hideDelay, () {
      _active = false;
      _changed();
    });
  }

  bool? _lastVisible;

  void _changed() {
    if (_disposed) {
      return;
    }
    final now = visible;
    if (now != _lastVisible) {
      _lastVisible = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// What the controls show and do; the page gives it (spherical_player_route.dart)
class SphericalControlsModel {
  const SphericalControlsModel({
    required this.title,
    required this.controller,
    required this.playing,
    required this.position,
    required this.duration,
    required this.bufferingPercent,
    required this.muted,
    required this.layout,
    required this.coverage,
    required this.raw,
    required this.onClose,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSkip,
    required this.onMute,
    required this.onLayout,
    required this.onCoverage,
  });

  final String title;
  final MediaKitVideoPlayerController controller;
  final bool playing;
  final Duration position;
  final Duration duration;

  /// The cache filled before the video plays on, null when it does not wait
  final int? bufferingPercent;
  final bool muted;
  final StereoLayout layout;
  final SphereCoverage coverage;

  /// A raw camera file: one picture over the whole sphere, no 3D and no 180 degrees
  final bool raw;
  final VoidCallback onClose;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSkip;
  final VoidCallback onMute;
  final VoidCallback onLayout;
  final VoidCallback onCoverage;
}

/// The overlay of the controls, see the top of this file
class SphericalControls extends StatelessWidget {
  const SphericalControls({super.key, required this.model, required this.visibility});

  final SphericalControlsModel model;
  final SphericalControlsVisibility visibility;

  static const _shadows = [Shadow(blurRadius: 6, color: Colors.black54)];
  static const skipStep = Duration(seconds: 10);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final buffering = model.bufferingPercent;
    return ListenableBuilder(
      listenable: visibility,
      builder: (context, _) {
        final visible = visibility.visible;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (buffering != null)
              Center(
                child: Semantics(
                  liveRegion: true,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            t.video_buffering(percent: '$buffering'),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !visible,
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: (focused) => visibility.focused = focused,
                  child: Column(
                    children: [
                      _bar(context, top: true, child: _topBar(context)),
                      const Spacer(),
                      _bar(context, top: false, child: _bottomBar(context)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _bar(BuildContext context, {required bool top, required Widget child}) => MouseRegion(
    onEnter: (_) => visibility.hovered = true,
    onExit: (_) => visibility.hovered = false,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: top,
        bottom: !top,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: child),
      ),
    ),
  );

  Widget _topBar(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        IconButton(
          key: const Key('spherical_close'),
          tooltip: t.close,
          onPressed: model.onClose,
          icon: const Icon(Icons.close, color: Colors.white, shadows: _shadows),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            model.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 16, shadows: _shadows),
          ),
        ),
        if (!model.raw) ...[
          TextButton(
            key: const Key('spherical_coverage'),
            onPressed: model.onCoverage,
            child: Tooltip(
              message: '${t.panorama_coverage}: ${model.coverage.label(t)}',
              child: Text(
                model.coverage.shortLabel,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, shadows: _shadows),
              ),
            ),
          ),
          IconButton(
            key: const Key('spherical_layout'),
            tooltip: '${t.panorama_stereo_layout}: ${model.layout.label(t)}',
            onPressed: model.onLayout,
            icon: Icon(
              model.layout == StereoLayout.mono ? Icons.threed_rotation_outlined : Icons.threed_rotation,
              color: Colors.white,
              shadows: _shadows,
            ),
          ),
        ],
        DesktopAudioTrackButton(controller: model.controller, shadows: _shadows),
        const DesktopFullScreenButton(),
      ],
    );
  }

  Widget _bottomBar(BuildContext context) {
    final t = context.t;
    final duration = model.duration;
    final position = model.position > duration ? duration : model.position;
    final max = duration.inMilliseconds.toDouble();
    return Row(
      children: [
        IconButton(
          key: const Key('spherical_play'),
          tooltip: model.playing ? t.pause : t.play,
          onPressed: model.onPlayPause,
          icon: Icon(model.playing ? Icons.pause : Icons.play_arrow, color: Colors.white, shadows: _shadows),
        ),
        IconButton(
          key: const Key('spherical_back'),
          tooltip: t.desktop_video_seek_back,
          onPressed: () => model.onSkip(-skipStep),
          icon: const Icon(Icons.replay_10, color: Colors.white, shadows: _shadows),
        ),
        IconButton(
          key: const Key('spherical_forward'),
          tooltip: t.desktop_video_seek_forward,
          onPressed: () => model.onSkip(skipStep),
          icon: const Icon(Icons.forward_10, color: Colors.white, shadows: _shadows),
        ),
        const SizedBox(width: 8),
        Text(
          formatPlayerTime(position),
          style: const TextStyle(color: Colors.white, shadows: _shadows),
        ),
        Expanded(
          child: Slider(
            key: const Key('spherical_time'),
            value: max <= 0 ? 0 : position.inMilliseconds.clamp(0, max).toDouble(),
            max: max <= 0 ? 1 : max,
            onChanged: max <= 0 ? null : (value) => model.onSeek(Duration(milliseconds: value.round())),
            semanticFormatterCallback: (value) => formatPlayerTime(Duration(milliseconds: value.round())),
          ),
        ),
        Text(
          formatPlayerTime(duration),
          style: const TextStyle(color: Colors.white, shadows: _shadows),
        ),
        IconButton(
          key: const Key('spherical_mute'),
          tooltip: model.muted ? t.desktop_video_unmute : t.desktop_video_mute,
          onPressed: model.onMute,
          icon: Icon(model.muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, shadows: _shadows),
        ),
      ],
    );
  }
}

/// [time] as the players show it: m:ss, or h:mm:ss from an hour
String formatPlayerTime(Duration time) {
  final seconds = time.inSeconds % 60;
  final minutes = time.inMinutes % 60;
  final hours = time.inHours;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '$minutes:${two(seconds)}';
}

/// Whether [event] is a key the controls react to by showing: anything pressed but the modifiers alone
bool showsControls(KeyEvent event) =>
    event is KeyDownEvent &&
    !{
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    }.contains(event.logicalKey);
