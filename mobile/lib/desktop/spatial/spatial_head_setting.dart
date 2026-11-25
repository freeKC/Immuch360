// The head tracking of Spatial 2.5D in Settings, Asset Viewer, Videos (the computers only, under the Spatial 2.5D
// switch): "Use the webcam for head tracking" (on by default; the webcam still opens only after the card of the first
// time, and only while a Spatial 2.5D view is on screen) and the webcam (infrared cameras marked, never the default).
// Listing the webcams opens none of them. What moves the view, the sensitivity and the reversed direction are the
// view's settings (lot feat-25d-photos-53).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
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
    final cameras = useMemoized(listCameras);
    final listed = useFuture(cameras);
    useValueChanged<bool, void>(webcam.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatialWebcam, webcam.value));
    });
    if (cameras == null) {
      // No head tracker on this computer: nothing to set
      return const SizedBox.shrink();
    }
    final known = listed.data ?? const <HeadCamera>[];
    return Column(
      key: const Key('spatial_head_setting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSwitchListTile(
          key: const Key('spatial_webcam_switch'),
          valueNotifier: webcam,
          title: context.t.desktop_spatial_webcam_setting,
          subtitle: context.t.desktop_spatial_webcam_setting_subtitle,
        ),
        if (webcam.value)
          ListTile(
            title: Text(context.t.desktop_spatial_camera_menu),
            trailing: DropdownButton<String>(
              key: const Key('spatial_camera_dropdown'),
              value: settings.cameraId ?? '',
              onChanged: (value) => unawaited(
                ref.read(settingsProvider).write(.viewerSpatialCamera, value == null || value.isEmpty ? null : value),
              ),
              items: [
                DropdownMenuItem(value: '', child: Text(context.t.desktop_spatial_camera_default)),
                for (final camera in known)
                  DropdownMenuItem(
                    value: camera.id,
                    child: Text(
                      camera.infrared ? context.t.desktop_spatial_camera_infrared(name: camera.name) : camera.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // The webcam picked earlier and not plugged in now stays listed, so that the menu shows the choice
                if (settings.cameraId != null && !known.any((camera) => camera.id == settings.cameraId))
                  DropdownMenuItem(value: settings.cameraId, child: Text(settings.cameraId!)),
              ],
            ),
          ),
      ],
    );
  }
}
