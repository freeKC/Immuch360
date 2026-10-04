import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class VideoViewerSettings extends HookConsumerWidget {
  const VideoViewerSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(appConfigProvider).viewer;
    final useAutoPlayVideo = useState(viewer.autoPlayVideo);
    final useLoopVideo = useState(viewer.loopVideo);
    // The source picked, null until the user picks one
    final usePickedVideoSource = useState(viewer.videoSource);
    final useSpatial25d = useState(viewer.spatial25d);
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull;
    // The Spatial 2.5D player is for phones: a Meta Quest has no use for it
    final isPhone = isHorizonOs == false;
    // Until the user picks a source, the one the players of this device follow: on a Meta Quest the immersive viewer's,
    // which plays the original within the decoders whatever the former switch to load the original video said, and
    // on a phone the one that switch stands for
    final shownVideoSource =
        usePickedVideoSource.value ??
        (isHorizonOs == true ? viewer.immersiveVideoSourcePolicy : viewer.videoSourcePolicy);

    useValueChanged<bool, void>(useAutoPlayVideo.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerAutoPlayVideo, useAutoPlayVideo.value));
    });
    useValueChanged<bool, void>(useLoopVideo.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerLoopVideo, useLoopVideo.value));
    });
    useValueChanged<bool, void>(useSpatial25d.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerSpatial25d, useSpatial25d.value));
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(title: context.t.videos, icon: Icons.video_camera_back_outlined),
        SettingsSwitchListTile(
          valueNotifier: useAutoPlayVideo,
          title: context.t.setting_video_viewer_auto_play_title,
          subtitle: context.t.setting_video_viewer_auto_play_subtitle,
        ),
        SettingsSwitchListTile(
          valueNotifier: useLoopVideo,
          title: context.t.setting_video_viewer_looping_title,
          subtitle: context.t.loop_videos_description,
        ),
        if (isPhone)
          SettingsSwitchListTile(
            valueNotifier: useSpatial25d,
            title: context.t.spatial_2_5d_experimental_title,
            subtitle: context.t.spatial_2_5d_experimental_subtitle,
          ),
        _VideoSourceSetting(
          value: shownVideoSource,
          // A tap on the source shown before any pick stores it as well: it only stood for the former switch, or for
          // the default of the immersive viewer, and the other players of the device may follow another one
          toggleable: usePickedVideoSource.value == null,
          onChanged: (value) {
            final picked = value ?? shownVideoSource;
            usePickedVideoSource.value = picked;
            unawaited(ref.read(settingsProvider).write(.viewerVideoSource, picked));
          },
        ),
      ],
    );
  }
}

/// Which file of a server video the players load (see chooseVideoSource), as radio tiles like the other choices of
/// the settings, with a description under the default one: its title alone does not tell what "decodes" covers.
///
/// [toggleable] lets a tap on the selected tile through, as [onChanged] with null.
class _VideoSourceSetting extends StatelessWidget {
  const _VideoSourceSetting({required this.value, required this.onChanged, this.toggleable = false});

  final VideoSourcePolicy value;
  final ValueChanged<VideoSourcePolicy?> onChanged;
  final bool toggleable;

  @override
  Widget build(BuildContext context) {
    final titleStyle = context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500);
    final options = [
      (
        VideoSourcePolicy.preferOriginalWithinDecoder,
        context.t.video_source_auto,
        context.t.video_source_auto_description,
      ),
      (VideoSourcePolicy.alwaysOriginal, context.t.video_source_original, null),
      (VideoSourcePolicy.alwaysTranscoded, context.t.video_source_transcoded, null),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: SettingsSubTitle(title: context.t.video_source_title),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            context.t.video_source_subtitle,
            style: context.textTheme.bodyMedium?.copyWith(color: context.textTheme.bodyMedium?.color?.withAlpha(215)),
          ),
        ),
        RadioGroup<VideoSourcePolicy>(
          groupValue: value,
          onChanged: onChanged,
          child: Column(
            children: [
              for (final (option, title, description) in options)
                RadioListTile<VideoSourcePolicy>(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  dense: true,
                  activeColor: context.primaryColor,
                  title: Text(title, style: titleStyle),
                  subtitle: description == null ? null : Text(description),
                  value: option,
                  toggleable: toggleable,
                  controlAffinity: ListTileControlAffinity.trailing,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
