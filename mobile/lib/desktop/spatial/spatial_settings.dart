// Spatial 2.5D on the computers (release 53, lot P2): its settings, under the Spatial 2.5D switch of Settings, Asset
// Viewer, Videos, while it is on: what moves the view, how far, and which way. Kept with the other settings, so that
// the settings file carries them. The webcam settings of the head tracker come with its own lot.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class DesktopSpatialSettings extends HookConsumerWidget {
  const DesktopSpatialSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final viewer = ref.watch(appConfigProvider.select((config) => config.viewer));
    final kinds = ref.watch(viewerPositionSourcesProvider).keys.toList();
    final kind = spatialStartKind(viewer.spatialMoveWith, kinds);
    final sensitivity = useState(viewer.spatialSensitivity.clamp(spatialSensitivityMin, spatialSensitivityMax));
    final reverse = useState(viewer.spatialReverse);
    useValueChanged<bool, void>(reverse.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatialReverse, reverse.value));
    });
    return Column(
      key: const Key('desktop_spatial_settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          key: const Key('desktop_spatial_move_with'),
          contentPadding: const EdgeInsets.only(left: 20, right: 12),
          title: Text(t.desktop_spatial_move_with),
          subtitle: Text(viewerPositionKindHint(kind, t)),
          trailing: DropdownButton<ViewerPositionKind>(
            value: kind,
            underline: const SizedBox.shrink(),
            onChanged: (picked) {
              if (picked != null) {
                unawaited(ref.read(settingsProvider).write(.viewerSpatialMoveWith, picked));
              }
            },
            items: [
              for (final item in kinds)
                DropdownMenuItem(value: item, child: Text(viewerPositionKindLabel(item, t))),
            ],
          ),
        ),
        ListTile(
          key: const Key('desktop_spatial_sensitivity'),
          contentPadding: const EdgeInsets.only(left: 20, right: 12),
          title: Text(t.desktop_spatial_sensitivity(percent: sensitivity.value)),
          subtitle: Slider(
            value: sensitivity.value.toDouble(),
            min: spatialSensitivityMin.toDouble(),
            max: spatialSensitivityMax.toDouble(),
            divisions: (spatialSensitivityMax - spatialSensitivityMin) ~/ 25,
            label: '${sensitivity.value} %',
            onChanged: (value) => sensitivity.value = value.round(),
            onChangeEnd: (value) =>
                unawaited(ref.read(settingsProvider).write(.viewerSpatialSensitivity, value.round())),
          ),
        ),
        SettingsSwitchListTile(
          key: const Key('desktop_spatial_reverse'),
          valueNotifier: reverse,
          title: t.desktop_spatial_reverse,
          subtitle: t.desktop_spatial_reverse_subtitle,
        ),
      ],
    );
  }
}
