// What a Spatial 2.5D view of the computers shows about the head tracking, for the photo page and the video route
// alike:
// - HeadTrackingOverlay: over the picture, the source attached while the view is on screen (a page covered by another
//   one is not), and the three below;
// - SpatialCameraIndicator: the camera icon while the webcam is open, its tooltip saying what is used;
// - SpatialConsentCard: the card of the first time, "Use the webcam" or "Use the mouse";
// - SpatialProblemNote: why the head cannot move the view, with the button of the camera settings where the system has
//   one and "Try the webcam again"; automatic framing or Center Stage that could not be turned off; the face not seen
//   for a while.
// The mouse, the sway and the keys are the view's own sources (lot feat-25d-photos-53): it takes the mouse while
// HeadPositionSource.usable is false.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:url_launcher/url_launcher.dart';

/// The message of a problem on this system
String spatialProblemText(BuildContext context, SpatialTrackingProblem problem, {TargetPlatform? platform}) {
  final system = platform ?? defaultTargetPlatform;
  return switch (problem) {
    SpatialTrackingProblem.cameraOff => switch (system) {
      TargetPlatform.windows => context.t.desktop_spatial_camera_off_windows,
      TargetPlatform.macOS => context.t.desktop_spatial_camera_off_macos,
      _ => context.t.desktop_spatial_camera_off_linux,
    },
    SpatialTrackingProblem.mediaFeaturePack => context.t.desktop_spatial_media_feature_pack,
    SpatialTrackingProblem.noCamera => context.t.desktop_spatial_no_camera,
    SpatialTrackingProblem.cameraBusy => context.t.desktop_spatial_camera_busy,
    SpatialTrackingProblem.cameraLost => context.t.desktop_spatial_camera_lost,
    SpatialTrackingProblem.unsupportedFormat => context.t.desktop_spatial_unsupported_format,
    SpatialTrackingProblem.failed => context.t.desktop_spatial_tracker_failed,
  };
}

/// See the top of this file
class HeadTrackingOverlay extends StatefulWidget {
  const HeadTrackingOverlay({super.key, required this.source});

  final HeadPositionSource source;

  @override
  State<HeadTrackingOverlay> createState() => _HeadTrackingOverlayState();
}

class _HeadTrackingOverlayState extends State<HeadTrackingOverlay> {
  @override
  void initState() {
    super.initState();
    _follow(true);
  }

  @override
  void didUpdateWidget(HeadTrackingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      final old = oldWidget.source;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.detach());
      _follow(true);
    }
  }

  @override
  void dispose() {
    widget.source.detach();
    super.dispose();
  }

  /// Attached while shown, after the frame: the listeners of the source may rebuild
  void _follow(bool shown) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (shown && TickerMode.valuesOf(context).enabled) {
        widget.source.attach();
      } else if (!shown) {
        widget.source.detach();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // A page covered by another one keeps its state: TickerMode says it is not shown, and the webcam closes
    final shown = TickerMode.valuesOf(context).enabled;
    if (shown != widget.source.onScreen) {
      _follow(shown);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(top: 8, right: 8, child: SpatialCameraIndicator(source: widget.source)),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListenableBuilder(
                listenable: widget.source,
                builder: (context, _) => widget.source.needsConsent
                    ? SpatialConsentCard(source: widget.source)
                    : SpatialProblemNote(source: widget.source),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The camera icon while the webcam is open
class SpatialCameraIndicator extends StatelessWidget {
  const SpatialCameraIndicator({super.key, required this.source});

  final HeadPositionSource source;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: source,
    builder: (context, _) {
      if (!source.cameraOpen) {
        return const SizedBox.shrink();
      }
      return Tooltip(
        key: const Key('spatial_camera_indicator'),
        message: context.t.desktop_spatial_camera_on,
        child: Semantics(
          label: context.t.desktop_spatial_camera_on,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.videocam_rounded, color: Colors.white, size: 20),
            ),
          ),
        ),
      );
    },
  );
}

/// The card of the first time the head is to move the view
class SpatialConsentCard extends StatelessWidget {
  const SpatialConsentCard({super.key, required this.source});

  final HeadPositionSource source;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('spatial_consent_card'),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.videocam_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(context.t.desktop_spatial_consent_title, style: Theme.of(context).textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(context.t.desktop_spatial_camera_intro),
          if (defaultTargetPlatform == TargetPlatform.macOS) ...[
            const SizedBox(height: 4),
            Text(context.t.desktop_spatial_consent_macos),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('spatial_consent_mouse'),
                onPressed: source.declineConsent,
                child: Text(context.t.desktop_spatial_use_mouse),
              ),
              FilledButton(
                key: const Key('spatial_consent_webcam'),
                onPressed: () => unawaited(source.acceptConsent()),
                child: Text(context.t.desktop_spatial_use_camera),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Why the head cannot move the view, or that automatic framing keeps the face in the middle, or that no face is seen;
/// nothing otherwise
class SpatialProblemNote extends StatelessWidget {
  const SpatialProblemNote({super.key, required this.source});

  final HeadPositionSource source;

  @override
  Widget build(BuildContext context) {
    final problem = source.problem;
    final String text;
    final List<Widget> actions;
    if (problem != null) {
      text = spatialProblemText(context, problem);
      final settings = cameraPrivacySettingsUri;
      actions = [
        if (problem == SpatialTrackingProblem.cameraOff && settings != null)
          TextButton(
            onPressed: () => unawaited(launchUrl(Uri.parse(settings))),
            child: Text(context.t.desktop_spatial_camera_settings),
          ),
        TextButton(
          key: const Key('spatial_try_again'),
          onPressed: () => unawaited(source.retry()),
          child: Text(context.t.desktop_spatial_try_again),
        ),
      ];
    } else if (source.cameraOpen && source.tracking.framing == AutoFramingState.stuckOn) {
      text = defaultTargetPlatform == TargetPlatform.macOS
          ? context.t.desktop_spatial_center_stage
          : context.t.desktop_spatial_auto_framing;
      actions = const [];
    } else if (source.cameraOpen && source.tracking.lostTooLong) {
      text = context.t.desktop_spatial_face_lost;
      actions = const [];
    } else {
      return const SizedBox.shrink();
    }
    return Card(
      key: const Key('spatial_problem_note'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
            ...actions,
          ],
        ),
      ),
    );
  }
}
