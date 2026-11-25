import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_button.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

/// Immuch360: "Play on..." of the asset the viewer shows (play_on_asset.dart), to a linked screen or a Cast device
/// through this phone's relay. In place of Immich's own Cast dialog, whose Cast device got a session key of the
/// account in its address (gcast.service.dart): here no credential leaves the phone. Not on a TV, the Quest nor a
/// computer, which are the screens; not for an asset on this device only.
class CastAction extends ActionBuilder {
  const CastAction();

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!canPlayOnScreens(ref)) {
      return null;
    }
    final asset = ref.watch(assetViewerProvider.select((state) => state.currentAsset));
    if (asset == null || ref.read(playOnAssetRequestProvider)(asset) == null) {
      return null;
    }
    final remote = ref.watch(remotePlaybackProvider);
    final cast = ref.watch(castPlaybackProvider);
    final sending = (remote != null && !remote.ended && !remote.lost) || (cast != null && cast.live);
    return .new(
      icon: sending ? Icons.cast_connected_rounded : Icons.cast_rounded,
      label: context.t.play_on_title,
      onAction: () => unawaited(showPlayOnSheetForAsset(context, ref, asset)),
    );
  }
}
