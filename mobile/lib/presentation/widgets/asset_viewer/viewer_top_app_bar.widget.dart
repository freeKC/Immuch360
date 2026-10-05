import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/motion_photo_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_kebab_menu.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/timezone.dart';
import 'package:immich_ui/immich_ui.dart';

class ViewerTopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const ViewerTopAppBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final album = ref.watch(currentRemoteAlbumProvider);

    final isInLockedView = ref.watch(inLockedViewProvider);
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));

    if (album != null && album.isActivityEnabled && album.isShared && asset is RemoteAsset) {
      ref.watch(Store.activity.list(album.id, assetId: asset.id));
    }

    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final double opacity =
        ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)) * (showingControls ? 1 : 0);

    final originalTheme = context.themeData;

    // Viewing in 360 changes nothing on the server: available in readonly mode and in the locked folder too.
    // Photos open the Flutter panorama viewer, videos the native player where the platform has one.
    // On a Meta Quest, server assets open in the immersive viewer, which also plays 360 videos.
    // The asset is 360 when the server flags it, or when the user chose "View as 360°" for it. Raw files of 360°
    // cameras are stitched by the app; the button of one that does not open (the other file of a split pair missing,
    // a layout this device does not play) says why.
    final hasPanoramaView =
        (ref.watch(isEquirectangularProvider(asset)) || ref.watch(rawMediaKindProvider(asset)) != null) &&
        ref.watch(can360ViewProvider(asset));
    final panoramaButton = hasPanoramaView
        ? IconButton(
            icon: const Icon(Icons.threesixty_rounded),
            tooltip: '360°',
            onPressed: () => unawaited(open360View(context, ref, asset)),
          )
        : null;

    // Spatial 2.5D, an experimental setting, plays stereoscopic videos with depth on phones only: never on a Meta
    // Quest, nor while the platform check is pending. Like 360, it changes nothing on the server.
    final isSpatialEnabled = ref.watch(appConfigProvider.select((config) => config.viewer.spatial25d));
    final isPhone = ref.watch(isHorizonOsProvider).valueOrNull == false;
    final VoidCallback? onSpatialPressed = switch (asset.type) {
      AssetType.video when isSpatialEnabled && isPhone => () => unawaited(openSpatialVideo(context, ref, asset)),
      _ => null,
    };
    final spatialButton = onSpatialPressed != null
        ? IconButton(
            icon: const Icon(Icons.threed_rotation_rounded),
            tooltip: context.t.spatial_2_5d,
            onPressed: onSpatialPressed,
          )
        : null;

    final actions = <Widget>[
      if (asset.isMotionPhoto) const MotionPhotoActionButton(iconOnly: true),
      if (album != null && album.isActivityEnabled && album.isShared)
        IconButton(
          icon: const Icon(Icons.chat_outlined),
          onPressed: () {
            unawaited(
              context.router.push(
                ActivitiesRoute(album: album, assetId: asset is RemoteAsset ? asset.id : null, assetName: asset.name),
              ),
            );
          },
        ),

      const ActionIconButton(action: FavoriteAction(source: .viewer)),

      ImmichColorOverride(color: null, child: ViewerKebabMenu(originalTheme: originalTheme)),
    ];

    final lockedViewActions = <Widget>[ViewerKebabMenu(originalTheme: originalTheme)];

    return IgnorePointer(
      ignoring: opacity < 1.0,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: Durations.short2,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: showingDetails
                        ? null
                        : const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black45, Colors.black12, Colors.transparent],
                            stops: [0.0, 0.7, 1.0],
                          ),
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: preferredSize.height,
                child: Theme(
                  data: context.themeData.copyWith(iconTheme: const IconThemeData(size: 22, color: Colors.white)),
                  child: NavigationToolbar(
                    centerMiddle: true,
                    leading: const _AppBarBackButton(),
                    middle: showingDetails ? null : _AssetInfoTitle(asset: asset),
                    trailing:
                        !showingDetails && (!isReadonlyModeEnabled || panoramaButton != null || spatialButton != null)
                        ? ImmichColorOverride(
                            color: Colors.white,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ?panoramaButton,
                                ?spatialButton,
                                if (!isReadonlyModeEnabled) ...(isInLockedView ? lockedViewActions : actions),
                              ],
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(60.0);
}

class _AppBarBackButton extends ConsumerWidget {
  const _AppBarBackButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: showingDetails ? context.colorScheme.surface : Colors.transparent,
        shape: const CircleBorder(),
        iconSize: 22,
        iconColor: showingDetails ? context.colorScheme.onSurface : Colors.white,
        padding: const EdgeInsets.all(10.0),
        elevation: showingDetails ? 4 : 0,
      ),
      onPressed: context.maybePop,
      child: const Icon(Icons.arrow_back_rounded),
    );
  }
}

class _AssetInfoTitle extends ConsumerWidget {
  final BaseAsset asset;

  const _AssetInfoTitle({required this.asset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exifInfo = ref.watch(assetExifProvider(asset)).valueOrNull;
    final alwaysUse24HourFormat = MediaQuery.alwaysUse24HourFormatOf(context);

    final (dateTime, _) = resolveAssetDateTime(asset, exifInfo);

    final dateFormatted = dateTime.formatDate();
    final timeFormatted = dateTime.formatTime(alwaysUse24HourFormat: alwaysUse24HourFormat);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(dateFormatted, style: context.textTheme.labelLarge?.copyWith(color: Colors.white)),
        Text(timeFormatted, style: context.textTheme.labelMedium?.copyWith(color: Colors.white70)),
      ],
    );
  }
}
