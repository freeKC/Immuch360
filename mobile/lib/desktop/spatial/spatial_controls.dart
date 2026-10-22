// The controls of the Spatial 2.5D player of the computers: those of the phones' player (the stereo layout, 360 or
// 180 degrees, the audio track, Recenter, the head sensitivity while the head is tracked, the slider from the left eye
// to the right one when it is not, the disparity map for troubleshooting) and those of the 360° player of the
// computers (close, title, full screen, play, 10 s back and forward, the time bar, mute), plus the menu of what moves
// the viewpoint: head tracking, "Follow the mouse", the webcams, and "Reverse head direction" for a webcam whose own
// software mirrors its pictures. They show and hide as the 360° player's do (SphericalControlsVisibility). And the card
// of the first time, which says what the webcam is for before the page opens it (SpatialCameraIntro).

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv show SpatialLayout;

/// The name of [layout] in the layout menu
String spatialLayoutLabel(Translations t, SpatialStereoLayout layout) => switch (layout) {
  SpatialStereoLayout.auto => t.spatial_layout_auto,
  SpatialStereoLayout.sideBySide => t.spatial_layout_side_by_side,
  SpatialStereoLayout.topBottom => t.spatial_layout_top_bottom,
  SpatialStereoLayout.sideBySideSwapped => t.spatial_layout_side_by_side_swapped,
  SpatialStereoLayout.topBottomSwapped => t.spatial_layout_top_bottom_swapped,
  SpatialStereoLayout.none => t.spatial_layout_none,
};

String _eyeLayoutLabel(Translations t, mkv.SpatialLayout layout) => switch (layout) {
  mkv.SpatialLayout.sideBySide => t.spatial_layout_side_by_side,
  mkv.SpatialLayout.topBottom => t.spatial_layout_top_bottom,
  mkv.SpatialLayout.sideBySideSwapped => t.spatial_layout_side_by_side_swapped,
  mkv.SpatialLayout.topBottomSwapped => t.spatial_layout_top_bottom_swapped,
  mkv.SpatialLayout.none => t.spatial_layout_none,
};

/// The card of the first time: Windows asks nothing before a desktop app opens the webcam, so the page says what the
/// webcam is for and that its pictures stay in memory, and asks, before it opens it
class SpatialCameraIntro extends StatelessWidget {
  const SpatialCameraIntro({super.key, required this.onUseWebcam, required this.onFollowMouse});

  final VoidCallback onUseWebcam;
  final VoidCallback onFollowMouse;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card(
          key: const Key('spatial_camera_intro'),
          color: Colors.black87,
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.videocam_outlined, color: Colors.white70),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(t.desktop_spatial_camera_intro, style: const TextStyle(color: Colors.white)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      key: const Key('spatial_camera_intro_mouse'),
                      onPressed: onFollowMouse,
                      child: Text(t.desktop_spatial_follow_mouse),
                    ),
                    FilledButton(
                      key: const Key('spatial_camera_intro_use'),
                      onPressed: onUseWebcam,
                      child: Text(t.desktop_spatial_use_camera),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the layout button says: "Auto: Side by side" tells what Auto picked, as on the phones
String spatialLayoutButtonLabel(Translations t, SpatialStereoLayout layout, mkv.SpatialLayout auto) =>
    layout == SpatialStereoLayout.auto
    ? '${t.spatial_layout_auto}: ${_eyeLayoutLabel(t, auto)}'
    : spatialLayoutLabel(t, layout);

/// The name of a webcam in the menu: an infrared one says so
String spatialCameraLabel(Translations t, HeadCamera camera) {
  final name = camera.name.isEmpty ? '?' : camera.name;
  return camera.infrared ? t.desktop_spatial_camera_infrared(name: name) : name;
}

/// What the controls show and do; the page gives it (spatial_player_route.dart)
class SpatialControlsModel {
  const SpatialControlsModel({
    required this.title,
    required this.controller,
    required this.playing,
    required this.position,
    required this.duration,
    required this.bufferingPercent,
    required this.muted,
    required this.layout,
    required this.autoLayout,
    required this.coverage,
    required this.source,
    required this.cameras,
    required this.camera,
    required this.cameraOpen,
    required this.trackingRunning,
    required this.faceLost,
    required this.sensitivity,
    required this.showSlider,
    required this.viewpoint,
    required this.showRecenter,
    required this.debug,
    required this.showDisparity,
    required this.onClose,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSkip,
    required this.onMute,
    required this.onLayout,
    required this.onCoverage,
    required this.onSource,
    required this.onCamera,
    required this.onSensitivity,
    required this.onSensitivityEnd,
    required this.onViewpointStart,
    required this.onViewpoint,
    required this.onViewpointEnd,
    required this.onRecenter,
    required this.onDisparity,
    this.reversed = false,
    this.onReversed,
  });

  final String title;
  final MediaKitVideoPlayerController controller;
  final bool playing;
  final Duration position;
  final Duration duration;
  final int? bufferingPercent;
  final bool muted;

  /// The layout chosen, and what Auto draws now
  final SpatialStereoLayout layout;
  final mkv.SpatialLayout autoLayout;

  /// The part of the sphere a 360° video covers, null for a flat video
  final SphereCoverage? coverage;

  /// What moves the viewpoint, the webcams for the menu, the one in use, and whether it is open
  final SpatialViewpointSource source;
  final List<HeadCamera> cameras;
  final HeadCamera? camera;
  final bool cameraOpen;

  /// The webcam runs with head tracking chosen: the sensitivity shows; [faceLost] says the face is not found
  final bool trackingRunning;
  final bool faceLost;
  final double sensitivity;

  /// The slider from the left eye to the right one, and the viewpoint it shows
  final bool showSlider;
  final double viewpoint;
  final bool showRecenter;

  /// The troubleshooting setting: the disparity map switch
  final bool debug;
  final bool showDisparity;

  final VoidCallback onClose;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSkip;
  final VoidCallback onMute;
  final ValueChanged<SpatialStereoLayout> onLayout;
  final VoidCallback onCoverage;
  final ValueChanged<SpatialViewpointSource> onSource;
  final ValueChanged<HeadCamera> onCamera;
  final ValueChanged<double> onSensitivity;
  final VoidCallback onSensitivityEnd;
  final VoidCallback onViewpointStart;
  final ValueChanged<double> onViewpoint;
  final VoidCallback onViewpointEnd;
  final VoidCallback onRecenter;
  final VoidCallback onDisparity;

  /// The head's direction reversed (a webcam that mirrors its own pictures)
  final bool reversed;
  final ValueChanged<bool>? onReversed;
}

/// What the head tracking menu holds
sealed class _SourceItem {
  const _SourceItem();
}

class _SourceChoice extends _SourceItem {
  const _SourceChoice(this.source);
  final SpatialViewpointSource source;
}

class _CameraChoice extends _SourceItem {
  const _CameraChoice(this.camera);
  final HeadCamera camera;
}

class _DisparityChoice extends _SourceItem {
  const _DisparityChoice();
}

class _ReverseChoice extends _SourceItem {
  const _ReverseChoice();
}

/// The overlay of the controls, see the top of this file
class SpatialControls extends StatelessWidget {
  const SpatialControls({super.key, required this.model, required this.visibility});

  final SpatialControlsModel model;
  final SphericalControlsVisibility visibility;

  static const _shadows = [Shadow(blurRadius: 6, color: Colors.black54)];
  static const _white = TextStyle(color: Colors.white, shadows: _shadows);

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
            if (model.faceLost)
              Positioned(
                top: 64,
                left: 0,
                right: 0,
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(t.spatial_tracking_lost, key: const Key('spatial_face_lost'), style: _white),
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
                      _bar(
                        context,
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [_viewpointRow(context), _bottomBar(context)],
                        ),
                      ),
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
    final coverage = model.coverage;
    final layoutText = spatialLayoutButtonLabel(t, model.layout, model.autoLayout);
    return Row(
      children: [
        IconButton(
          key: const Key('spatial_close'),
          tooltip: t.close,
          onPressed: model.onClose,
          icon: const Icon(Icons.close, color: Colors.white, shadows: _shadows),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(model.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _white.copyWith(fontSize: 16)),
        ),
        if (coverage != null)
          TextButton(
            key: const Key('spatial_coverage'),
            onPressed: model.onCoverage,
            child: Tooltip(
              message: '${t.panorama_coverage}: ${coverage.label(t)}',
              child: Text(coverage.shortLabel, style: _white.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        PopupMenuButton<SpatialStereoLayout>(
          key: const Key('spatial_layout'),
          tooltip: t.spatial_layout,
          initialValue: model.layout,
          onSelected: model.onLayout,
          itemBuilder: (context) => [
            for (final layout in SpatialStereoLayout.values)
              CheckedPopupMenuItem(
                value: layout,
                checked: layout == model.layout,
                child: Text(spatialLayoutLabel(t, layout)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Semantics(
              label: '${t.spatial_layout}: $layoutText',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.threed_rotation, color: Colors.white, shadows: _shadows),
                  const SizedBox(width: 6),
                  Text(layoutText, style: _white),
                ],
              ),
            ),
          ),
        ),
        _sourceMenu(context),
        DesktopAudioTrackButton(controller: model.controller, shadows: _shadows),
        const DesktopFullScreenButton(),
      ],
    );
  }

  Widget _sourceMenu(BuildContext context) {
    final t = context.t;
    final icon = switch (model.source) {
      SpatialViewpointSource.head => model.cameraOpen ? Icons.face : Icons.face_retouching_off,
      SpatialViewpointSource.mouse => Icons.mouse,
      SpatialViewpointSource.manual => Icons.tune,
    };
    return PopupMenuButton<_SourceItem>(
      key: const Key('spatial_source'),
      tooltip: t.desktop_spatial_head_tracking,
      icon: Icon(icon, color: Colors.white, shadows: _shadows),
      onSelected: (item) {
        switch (item) {
          case _SourceChoice(:final source):
            // Unchecking the item in use leaves the slider and the keys
            model.onSource(source == model.source ? SpatialViewpointSource.manual : source);
          case _CameraChoice(:final camera):
            model.onCamera(camera);
          case _DisparityChoice():
            model.onDisparity();
          case _ReverseChoice():
            model.onReversed?.call(!model.reversed);
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: const Key('spatial_source_head'),
          value: const _SourceChoice(SpatialViewpointSource.head),
          checked: model.source == SpatialViewpointSource.head,
          child: Text(t.desktop_spatial_head_tracking),
        ),
        CheckedPopupMenuItem(
          key: const Key('spatial_source_mouse'),
          value: const _SourceChoice(SpatialViewpointSource.mouse),
          checked: model.source == SpatialViewpointSource.mouse,
          child: Text(t.desktop_spatial_follow_mouse),
        ),
        if (model.cameras.isNotEmpty) ...[
          const PopupMenuDivider(),
          PopupMenuItem(enabled: false, height: 32, child: Text(t.desktop_spatial_camera_menu)),
          for (final camera in model.cameras)
            CheckedPopupMenuItem(
              value: _CameraChoice(camera),
              checked: camera == model.camera && model.source == SpatialViewpointSource.head,
              child: Text(spatialCameraLabel(t, camera)),
            ),
          // For a webcam whose own software mirrors its pictures: the depth would move the wrong way
          if (model.onReversed != null)
            CheckedPopupMenuItem(
              key: const Key('spatial_reverse_head'),
              value: const _ReverseChoice(),
              checked: model.reversed,
              child: Text(t.desktop_spatial_reverse_head),
            ),
        ],
        if (model.debug) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
            key: const Key('spatial_disparity'),
            value: const _DisparityChoice(),
            checked: model.showDisparity,
            child: Text(t.desktop_spatial_disparity_map),
          ),
        ],
      ],
    );
  }

  /// Recenter, the sensitivity while the head is tracked, the slider from the left eye to the right one
  Widget _viewpointRow(BuildContext context) {
    final t = context.t;
    final children = <Widget>[
      if (model.showRecenter)
        TextButton.icon(
          key: const Key('spatial_recenter'),
          onPressed: model.onRecenter,
          icon: const Icon(Icons.center_focus_strong, color: Colors.white, shadows: _shadows),
          label: Text(t.spatial_recenter, style: _white),
        ),
      if (model.trackingRunning) ...[
        const SizedBox(width: 12),
        Text('${t.spatial_sensitivity} ${model.sensitivity.toStringAsFixed(1)}', style: _white),
        SizedBox(
          width: 180,
          child: Slider(
            key: const Key('spatial_sensitivity'),
            value: model.sensitivity.clamp(HeadViewpoint.minSensitivity, HeadViewpoint.maxSensitivity),
            min: HeadViewpoint.minSensitivity,
            max: HeadViewpoint.maxSensitivity,
            divisions: ((HeadViewpoint.maxSensitivity - HeadViewpoint.minSensitivity) * 10).round(),
            label: model.sensitivity.toStringAsFixed(1),
            onChanged: model.onSensitivity,
            onChangeEnd: (_) => model.onSensitivityEnd(),
          ),
        ),
      ],
      if (model.showSlider) ...[
        const SizedBox(width: 12),
        const Text('L', style: _white),
        Expanded(
          child: Slider(
            key: const Key('spatial_viewpoint'),
            value: model.viewpoint.clamp(0.0, 1.0),
            onChangeStart: (_) => model.onViewpointStart(),
            onChanged: model.onViewpoint,
            onChangeEnd: (_) => model.onViewpointEnd(),
            semanticFormatterCallback: (value) => '${t.desktop_spatial_viewpoint} ${(value * 100).round()}%',
          ),
        ),
        const Text('R', style: _white),
      ] else
        const Spacer(),
    ];
    if (!model.showRecenter && !model.trackingRunning && !model.showSlider) {
      return const SizedBox.shrink();
    }
    return Row(children: children);
  }

  Widget _bottomBar(BuildContext context) {
    final t = context.t;
    final duration = model.duration;
    final position = model.position > duration ? duration : model.position;
    final max = duration.inMilliseconds.toDouble();
    return Row(
      children: [
        IconButton(
          key: const Key('spatial_play'),
          tooltip: model.playing ? t.pause : t.play,
          onPressed: model.onPlayPause,
          icon: Icon(model.playing ? Icons.pause : Icons.play_arrow, color: Colors.white, shadows: _shadows),
        ),
        IconButton(
          tooltip: t.desktop_video_seek_back,
          onPressed: () => model.onSkip(-SphericalControls.skipStep),
          icon: const Icon(Icons.replay_10, color: Colors.white, shadows: _shadows),
        ),
        IconButton(
          tooltip: t.desktop_video_seek_forward,
          onPressed: () => model.onSkip(SphericalControls.skipStep),
          icon: const Icon(Icons.forward_10, color: Colors.white, shadows: _shadows),
        ),
        const SizedBox(width: 8),
        Text(formatPlayerTime(position), style: _white),
        Expanded(
          child: Slider(
            key: const Key('spatial_time'),
            value: max <= 0 ? 0 : position.inMilliseconds.clamp(0, max).toDouble(),
            max: max <= 0 ? 1 : max,
            onChanged: max <= 0 ? null : (value) => model.onSeek(Duration(milliseconds: value.round())),
            semanticFormatterCallback: (value) => formatPlayerTime(Duration(milliseconds: value.round())),
          ),
        ),
        Text(formatPlayerTime(duration), style: _white),
        IconButton(
          tooltip: model.muted ? t.desktop_video_unmute : t.desktop_video_mute,
          onPressed: model.onMute,
          icon: Icon(model.muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, shadows: _shadows),
        ),
      ],
    );
  }
}

/// A message of the page over the picture: a tracking problem with its button, the flat video, the transcoded stream
class SpatialMessage {
  const SpatialMessage({required this.key, required this.text, this.action, this.onAction, this.onClose});

  final String key;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onClose;
}

/// The messages, above the bottom bar, one under the other; each one can be closed
class SpatialMessages extends StatelessWidget {
  const SpatialMessages({super.key, required this.messages});

  final List<SpatialMessage> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final message in messages)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: DecoratedBox(
                  key: Key('spatial_message_${message.key}'),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(message.text, style: const TextStyle(color: Colors.white)),
                        ),
                        if (message.action != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            key: Key('spatial_message_${message.key}_action'),
                            onPressed: message.onAction,
                            child: Text(message.action!),
                          ),
                        ],
                        if (message.onClose != null)
                          IconButton(
                            tooltip: t.close,
                            onPressed: message.onClose,
                            icon: const Icon(Icons.close, color: Colors.white, size: 18),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
