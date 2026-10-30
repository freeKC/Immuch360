import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

/// Which file of a server video the in-app player plays, the original or the server's copy, and why when the decoder
/// check chose it (see chooseVideoSource), with the other file to play instead: the user can still force it, for this
/// video and as long as the app runs (videoSourceOverridesProvider), the immersive viewer of the Meta Quest included.
/// Nothing before the player chose, nor for a file only on the device; no other file when the server has no copy of
/// its own, asked here when the player did not need to know (see serverHasCopyProvider).
class VideoSourceTile extends ConsumerWidget {
  const VideoSourceTile({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = this.asset;
    final videoId = (asset is RemoteAsset ? asset.livePhotoVideoId : null) ?? asset.remoteId;
    if (videoId == null) {
      return const SizedBox.shrink();
    }
    final chosen = ref.watch(chosenVideoSourcesProvider.select((sources) => sources[videoId]));
    if (chosen == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    // Asked here when the player chose without knowing: no copy to offer while the answer comes
    final hasCopy = chosen.hasCopy ?? ref.watch(serverHasCopyProvider(videoId)).value;
    // The server's playback stream of a video it did not transcode is its original
    final playsOriginal = chosen.kind == VideoSourceKind.original || hasCopy == false;
    final why = chosen.refusal?.message(t) ?? chosen.notice?.message(t);
    final titleStyle = context.textTheme.labelLarge;
    final subtitleStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);
    final other = playsOriginal ? VideoSourceKind.transcoded : VideoSourceKind.original;
    return Column(
      children: [
        const SizedBox(height: 16),
        SheetTile(
          title: t.video_source_title,
          titleStyle: titleStyle,
          leading: Icon(Icons.swap_horiz_rounded, size: 24, color: titleStyle?.color),
          subtitle: [playsOriginal ? t.video_source_the_original : t.video_source_the_copy, ?why].join('\n'),
          subtitleStyle: subtitleStyle,
          trailing: hasCopy == true
              ? TextButton(
                  onPressed: () => ref.read(videoSourceOverridesProvider.notifier).force(videoId, other),
                  child: Text(playsOriginal ? t.video_source_play_copy : t.video_source_play_original),
                )
              : null,
        ),
      ],
    );
  }
}
