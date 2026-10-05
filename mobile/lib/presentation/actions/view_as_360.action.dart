import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';

/// Views a photo or a video as 360° although the server does not flag it, nor its file on the device, for 360° files
/// that carry no projection tag, then opens it in 360°. Once chosen, the action offers to stop treating it as 360°
/// instead. The choice stays on the device (see [ForcedPanoramaAssets]) and changes nothing on the server, so it is
/// offered wherever the 360° view is, in the locked folder too.
class ViewAs360Action extends AssetActionBuilder {
  const ViewAs360Action({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetsActionProvider(source)).singleOrNull;
    if (asset == null) {
      return null;
    }
    // A raw file of a 360° camera has the 360° button, which stitches it: viewed as 360° it would be read as an
    // equirect picture
    if (ref.watch(rawMediaKindProvider(asset)) != null) {
      return null;
    }
    // Until the exif has loaded, nothing tells whether the server flags the asset as 360°. When it does, or when the
    // file on the device declares it, the asset is 360° already, and the choice of the user would change nothing.
    if (ref.watch(isFoundLocalPanoramaProvider(asset))) {
      return null;
    }
    final isExifLoading = ref.watch(assetExifProvider(asset).select((exif) => exif.isLoading && !exif.hasValue));
    if (isExifLoading || ref.watch(hasEquirectangularExifProvider(asset))) {
      return null;
    }

    if (ref.watch(isForcedPanoramaProvider(asset))) {
      return .new(
        icon: Icons.undo_rounded,
        label: context.t.view_as_360_remove,
        onAction: () => ref.read(forcedPanoramaAssetsProvider.notifier).remove(asset),
      );
    }
    if (!ref.watch(can360ViewProvider(asset))) {
      return null;
    }
    return .new(
      icon: Icons.threesixty_rounded,
      label: context.t.view_as_360,
      onAction: () => _viewAs360(context, ref, asset),
    );
  }

  Future<void> _viewAs360(BuildContext context, WidgetRef ref, BaseAsset asset) async {
    await ref.read(forcedPanoramaAssetsProvider.notifier).add(asset);
    if (!context.mounted) {
      return;
    }
    // Not awaited, so that the menu closes right away: it waits for the action
    unawaited(open360View(context, ref, asset));
  }
}
