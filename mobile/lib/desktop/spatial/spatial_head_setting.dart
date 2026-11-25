// "Spatial 2.5D on this computer" in Settings, Asset Viewer, Videos (the computers only, under the Spatial 2.5D switch):
// Move the view with (Head, Mouse, Automatic sway, Keys only), Use the webcam for head tracking (on by default; the
// webcam still opens only after the card of the first time, and only while a Spatial 2.5D view is on screen), the
// webcam (infrared cameras marked, never the default), Reverse head direction and the head sensitivity. Listing the
// webcams opens none of them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_input_widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

/// The webcams of this computer for the menu, null when the computer has no head tracker; opens no webcam
typedef SpatialCameraLister = Future<List<HeadCamera>>? Function();

Future<List<HeadCamera>>? _listCameras() => NativeSpatialHeadSource.desktop()?.cameras();

class SpatialHeadTrackingSetting extends HookConsumerWidget {
  const SpatialHeadTrackingSetting({super.key, this.listCameras = _listCameras});

  final SpatialCameraLister listCameras;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(appConfigProvider.select((config) => config.viewer));
    final settings = DesktopSpatialSettings.fromViewer(viewer);
    final webcam = useState(settings.webcam);
    final reverse = useState(settings.reverseHead);
    final sensitivity = useState((settings.sensitivity * 10).round());
    final cameras = useMemoized(listCameras);
    final listed = useFuture(cameras);
    useValueChanged<bool, void>(webcam.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatialWebcam, webcam.value));
    });
    useValueChanged<bool, void>(reverse.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatialReverseHead, reverse.value));
    });
    useValueChanged<int, void>(sensitivity.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatialSensitivity, sensitivity.value));
    });
    final headSupported = cameras != null;
    final inputs = [
      for (final input in ViewerInput.values)
        if (input != ViewerInput.head || headSupported) input,
    ];
    final shown = settings.input ?? (headSupported && settings.webcam ? ViewerInput.head : ViewerInput.mouse);
    return Column(
      key: const Key('spatial_head_setting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(t.desktop_spatial_move_with),
          subtitle: Text(t.desktop_spatial_settings_title),
          trailing: DropdownButton<ViewerInput>(
            key: const Key('spatial_input_dropdown'),
            value: inputs.contains(shown) ? shown : ViewerInput.mouse,
            onChanged: (value) {
              if (value != null) {
                unawaited(ref.read(settingsProvider).write(.viewerSpatialInput, DesktopSpatialSettings.nameOf(value)));
              }
            },
            items: [for (final input in inputs) DropdownMenuItem(value: input, child: Text(spatialInputLabel(input)))],
          ),
        ),
        if (headSupported) ...[
          SettingsSwitchListTile(
            key: const Key('spatial_webcam_switch'),
            valueNotifier: webcam,
            title: t.desktop_spatial_webcam_setting,
            subtitle: t.desktop_spatial_webcam_setting_subtitle,
          ),
          if (webcam.value) ...[
            ListTile(
              title: Text(t.desktop_spatial_camera_menu),
              trailing: DropdownButton<String>(
                key: const Key('spatial_camera_dropdown'),
                value: settings.cameraId ?? '',
                onChanged: (value) => unawaited(
                  ref.read(settingsProvider).write(.viewerSpatialCamera, value == null || value.isEmpty ? null : value),
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(t.desktop_spatial_camera_default)),
                  for (final camera in listed.data ?? const <HeadCamera>[])
                    DropdownMenuItem(
                      value: camera.id,
                      child: Text(
                        camera.infrared ? t.desktop_spatial_camera_infrared(name: camera.name) : camera.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // The webcam picked earlier and not plugged in now stays listed, so that the menu shows the choice
                  if (settings.cameraId != null &&
                      !(listed.data ?? const <HeadCamera>[]).any((camera) => camera.id == settings.cameraId))
                    DropdownMenuItem(value: settings.cameraId, child: Text(settings.cameraId!)),
                ],
              ),
            ),
            SettingsSwitchListTile(
              key: const Key('spatial_reverse_switch'),
              valueNotifier: reverse,
              title: t.desktop_spatial_reverse_head,
            ),
            SettingsSliderListTile(
              key: const Key('spatial_sensitivity_slider'),
              valueNotifier: sensitivity,
              text: '${t.desktop_spatial_sensitivity}: ${(sensitivity.value / 10).toStringAsFixed(1)}',
              minValue: HeadViewpoint.minSensitivity * 10,
              maxValue: HeadViewpoint.maxSensitivity * 10,
              noDivisons: ((HeadViewpoint.maxSensitivity - HeadViewpoint.minSensitivity) * 10).round(),
            ),
          ],
        ],
      ],
    );
  }
}
