// What a Spatial 2.5D view of the computers shows about its input, for the photo page and the video route alike:
// - SpatialViewerInputArea: around the picture, the mouse over it and the keys (left and right arrows, R recenters)
//   handed to the SpatialViewerInput, the view attached while it is on screen, and the overlays below;
// - SpatialCameraIndicator: the camera icon while the webcam is open, its tooltip saying what is used;
// - SpatialConsentCard: the card of the first time, "Use the webcam" or "Use the mouse";
// - SpatialProblemNote: why the head cannot move the view, with the button of the camera settings where the system has
//   one, or "Try the webcam again";
// - SpatialInputMenu: Move the view with, and Reverse head direction.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewer_input.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:url_launcher/url_launcher.dart';

/// The label of an input in the menus
String spatialInputLabel(ViewerInput input) => switch (input) {
  ViewerInput.head => t.desktop_spatial_input_head,
  ViewerInput.mouse => t.desktop_spatial_input_mouse,
  ViewerInput.sway => t.desktop_spatial_input_sway,
  ViewerInput.keys => t.desktop_spatial_input_keys,
};

/// The message of a problem on this system
String spatialProblemText(SpatialTrackingProblem problem, {TargetPlatform? platform}) {
  final system = platform ?? defaultTargetPlatform;
  return switch (problem) {
    SpatialTrackingProblem.cameraOff => switch (system) {
      TargetPlatform.windows => t.desktop_spatial_camera_off_windows,
      TargetPlatform.macOS => t.desktop_spatial_camera_off_macos,
      _ => t.desktop_spatial_camera_off_linux,
    },
    SpatialTrackingProblem.mediaFeaturePack => t.desktop_spatial_media_feature_pack,
    SpatialTrackingProblem.noCamera => t.desktop_spatial_no_camera,
    SpatialTrackingProblem.cameraBusy => t.desktop_spatial_camera_busy,
    SpatialTrackingProblem.cameraLost => t.desktop_spatial_camera_lost,
    SpatialTrackingProblem.unsupportedFormat => t.desktop_spatial_unsupported_format,
    SpatialTrackingProblem.failed => t.desktop_spatial_tracker_failed,
  };
}

/// See the top of this file
class SpatialViewerInputArea extends StatefulWidget {
  const SpatialViewerInputArea({super.key, required this.input, required this.child, this.autofocus = true});

  final SpatialViewerInput input;

  /// The picture
  final Widget child;
  final bool autofocus;

  @override
  State<SpatialViewerInputArea> createState() => _SpatialViewerInputAreaState();
}

class _SpatialViewerInputAreaState extends State<SpatialViewerInputArea> {
  @override
  void initState() {
    super.initState();
    _follow(true);
  }

  /// Attached while shown, after the frame: the listeners of the input may rebuild
  void _follow(bool shown) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (shown && TickerMode.of(context)) {
        widget.input.attach();
      } else if (!shown) {
        widget.input.detach();
      }
    });
  }

  @override
  void didUpdateWidget(SpatialViewerInputArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.input, widget.input)) {
      final old = oldWidget.input;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.detach());
      _follow(true);
    }
  }

  @override
  void dispose() {
    widget.input.detach();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.input.step(-SpatialViewerInput.keyStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.input.step(SpatialViewerInput.keyStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      widget.input.recenter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // A page covered by another one keeps its state: TickerMode tells it is not shown, and the webcam closes
    final shown = TickerMode.of(context);
    if (shown != widget.input.onScreen) {
      _follow(shown);
    }
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          onHover: (event) => widget.input.pointer(event.localPosition.dx / constraints.maxWidth),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              Positioned(top: 8, right: 8, child: SpatialCameraIndicator(input: widget.input)),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: ListenableBuilder(
                      listenable: widget.input,
                      builder: (context, _) => widget.input.needsConsent
                          ? SpatialConsentCard(input: widget.input)
                          : SpatialProblemNote(input: widget.input),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The camera icon while the webcam is open
class SpatialCameraIndicator extends StatelessWidget {
  const SpatialCameraIndicator({super.key, required this.input});

  final SpatialViewerInput input;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: input,
    builder: (context, _) {
      if (!input.cameraOpen) {
        return const SizedBox.shrink();
      }
      return Tooltip(
        key: const Key('spatial_camera_indicator'),
        message: t.desktop_spatial_camera_on,
        child: Semantics(
          label: t.desktop_spatial_camera_on,
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
  const SpatialConsentCard({super.key, required this.input});

  final SpatialViewerInput input;

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
              Expanded(child: Text(t.desktop_spatial_consent_title, style: Theme.of(context).textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 8),
          Text(t.desktop_spatial_camera_intro),
          if (defaultTargetPlatform == TargetPlatform.macOS) ...[
            const SizedBox(height: 4),
            Text(t.desktop_spatial_consent_macos),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('spatial_consent_mouse'),
                onPressed: () => unawaited(input.declineConsent()),
                child: Text(t.desktop_spatial_use_mouse),
              ),
              FilledButton(
                key: const Key('spatial_consent_webcam'),
                onPressed: () => unawaited(input.acceptConsent()),
                child: Text(t.desktop_spatial_use_camera),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Why the head cannot move the view, or that automatic framing keeps the face in the middle; nothing otherwise
class SpatialProblemNote extends StatelessWidget {
  const SpatialProblemNote({super.key, required this.input});

  final SpatialViewerInput input;

  @override
  Widget build(BuildContext context) {
    final problem = input.problem;
    final String text;
    final List<Widget> actions;
    if (problem != null) {
      text = spatialProblemText(problem);
      final settings = cameraPrivacySettingsUri;
      actions = [
        if (problem == SpatialTrackingProblem.cameraOff && settings != null)
          TextButton(
            onPressed: () => unawaited(launchUrl(Uri.parse(settings))),
            child: Text(t.desktop_spatial_camera_settings),
          ),
        TextButton(
          key: const Key('spatial_try_again'),
          onPressed: () => unawaited(input.retry()),
          child: Text(t.desktop_spatial_try_again),
        ),
      ];
    } else if (input.input == ViewerInput.head && input.tracking.framing == AutoFramingState.stuckOn) {
      text = defaultTargetPlatform == TargetPlatform.macOS
          ? t.desktop_spatial_center_stage
          : t.desktop_spatial_auto_framing;
      actions = const [];
    } else if (input.input == ViewerInput.head && input.tracking.lostTooLong) {
      text = t.desktop_spatial_face_lost;
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

/// Move the view with, and Reverse head direction
class SpatialInputMenu extends StatelessWidget {
  const SpatialInputMenu({super.key, required this.input});

  final SpatialViewerInput input;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: input,
    builder: (context, _) => PopupMenuButton<Object>(
      key: const Key('spatial_input_menu'),
      tooltip: t.desktop_spatial_move_with,
      icon: Icon(switch (input.input) {
        ViewerInput.head => Icons.face_retouching_natural,
        ViewerInput.mouse => Icons.mouse_outlined,
        ViewerInput.sway => Icons.swap_horiz,
        ViewerInput.keys => Icons.keyboard_outlined,
      }),
      onSelected: (value) {
        if (value is ViewerInput) {
          unawaited(input.choose(value));
        } else if (value == #reverse) {
          unawaited(input.setReverseHead(!input.settings.reverseHead));
        }
      },
      itemBuilder: (context) => [
        for (final value in ViewerInput.values)
          if (value != ViewerInput.head || input.headSupported)
            CheckedPopupMenuItem<Object>(
              value: value,
              checked: input.chosen == value,
              child: Text(spatialInputLabel(value)),
            ),
        if (input.headSupported) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(
            value: #reverse,
            checked: input.settings.reverseHead,
            child: Text(t.desktop_spatial_reverse_head),
          ),
        ],
      ],
    ),
  );
}
