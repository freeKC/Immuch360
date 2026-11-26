// "Slideshow on…" of a selection of the timeline (release 53): the selected photos and videos of the Immich library,
// in the timeline's order (the newest first), go to a linked screen or a Cast device as a slideshow the phone steps
// through (play_on_asset.dart). On a phone or a tablet only; none of them on this device only, nothing to send.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_button.widget.dart';

class PlayOnSlideshowAction extends AssetActionBuilder {
  const PlayOnSlideshowAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!canPlayOnScreens(ref)) {
      return null;
    }
    final assets = ref.watch(assetsActionProvider(source)).where((asset) => asset.hasRemote).toList();
    if (assets.isEmpty) {
      return null;
    }
    return .new(
      icon: Icons.cast_rounded,
      label: context.t.play_on_slideshow,
      onAction: () => unawaited(showPlayOnSlideshow(context, ref, playOnTimelineOrder(assets))),
    );
  }
}

/// [assets] in the timeline's order: the newest first
List<BaseAsset> playOnTimelineOrder(Iterable<BaseAsset> assets) =>
    assets.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
