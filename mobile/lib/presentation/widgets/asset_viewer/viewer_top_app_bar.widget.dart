import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_preview.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/motion_photo_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/scene_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/rotate_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_date_time.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_kebab_menu.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/scene_photo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('ViewerTopAppBar');

class ViewerTopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const ViewerTopAppBar({super.key, this.trailingFocusNode});

  /// Around the buttons on the right (360°, 3D, the actions): where Up of a remote goes
  final FocusNode? trailingFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final album = ref.watch(currentRemoteAlbumProvider);

    final isInLockedView = ref.watch(inLockedViewProvider);
    // The read only mode, or a TV, where the app is a viewer: the favourite and the menu (cast among others) hide
    final isViewOnly = ref.watch(viewOnlyProvider);
    final isTv = ref.watch(tvModeProvider);

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
    // Not a TV either: Spatial 2.5D follows the head with the front camera
    final isPhone = ref.watch(isHorizonOsProvider).valueOrNull == false && !ref.watch(tvModeProvider);
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

    // An Apple spatial photo shows its two eyes in the immersive viewer of a Meta Quest; the other devices show the left
    // eye, as for any photo. Only HEIF photos are read for a pair, and only on the headset.
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final stereoPair = isHorizonOs && asset.isImage && isHeifName(asset.name)
        ? ref.watch(appleSpatialInfoProvider(asset)).valueOrNull?.photo
        : null;
    // So does a flat photo holding two eyes side by side: the 3D photos a computer makes, those of other tools. Only
    // the photos whose name or frame says so are read (see FlatStereoService.isCandidate), only on the headset, and
    // never a photo shown as 360°, which keeps its own viewer (a band of the sphere has the frame of two eyes). One of
    // a newer format keeps its button, greyed with the reason.
    final flatStereoState = isHorizonOs && asset.isImage && stereoPair == null && !hasPanoramaView
        ? ref.watch(flatStereoProvider(asset))
        : null;
    final flatStereo = flatStereoState?.valueOrNull;
    final sbsRequest = flatStereo?.request;
    // A flat 3D media told by its file name (experimental, on by default, Settings, Advanced): a video whose name
    // says it holds two eyes (_SBS, _HSBS, _LR, _TB, _OU, Half-SBS...) on the flat video screen of the immersive
    // viewer, and a photo of two eyes one above the other on the stereo quad, nothing to read for either; never a media
    // shown as 360°, nor a photo the reads above found otherwise
    final flat3dByName =
        isHorizonOs && !hasPanoramaView && ref.watch(appConfigProvider.select((config) => config.viewer.flat3dByName));
    final flatVideoFormat = flat3dByName ? flatStereoVideoFormatOf(asset) : null;
    final stackedPhoto = flat3dByName && asset.isImage ? stackedPhotoFormatOf(asset.name) : null;
    final stackedPhotoFormat = stereoPair == null && flatStereo == null ? stackedPhoto : null;
    final StereoPhotoRequest? stereoRequest = stereoPair != null
        ? StereoPhotoRequest.heic(stereoPair)
        : sbsRequest != null
        ? StereoPhotoRequest.sbs(sbsRequest)
        : stackedPhotoFormat != null
        ? StereoPhotoRequest.flat3d(Flat3dRequest(stackedPhotoFormat))
        : null;
    final VoidCallback? onView3d = stereoRequest != null
        ? () => unawaited(_openStereoPhoto(context, ref, asset, stereoRequest))
        : flatVideoFormat != null
        ? () => unawaited(_openFlatVideo(context, ref, asset, flatVideoFormat))
        : null;
    final hasView3d = stereoPair != null || flatStereo != null || stackedPhotoFormat != null || flatVideoFormat != null;
    final view3dButton = hasView3d
        ? IconButton(
            key: const Key('apple_spatial_view_3d'),
            icon: const Icon(Icons.view_in_ar_rounded),
            tooltip: onView3d != null ? context.t.apple_spatial_view_3d : context.t.ai_immersive_newer_version,
            onPressed: onView3d,
          )
        : null;

    // "Explore the 3D scene" on a Meta Quest: a photo named like one that carries a 3D scene a computer made from it,
    // told by our packet at the head of its file; greyed with the reason the gate of the headset reads there (see
    // AiSceneButton). Nothing of the AI is needed to read a scene: the AI features off leave it.
    final sceneState = isHorizonOs && ScenePhotoService.isCandidate(asset) && !hasPanoramaView
        ? ref.watch(scenePhotoProvider(asset))
        : null;
    final sceneXmp = sceneState?.valueOrNull;
    final sceneButton = sceneXmp != null
        ? AiSceneButton(xmp: sceneXmp, open: (stereo) => _openStereoPhoto(context, ref, asset, stereo))
        : null;

    // "AI relief" on a Meta Quest: a flat photo once known to be one (neither 360°, VR180 nor raw, nor a spatial photo,
    // nor two eyes side by side: the one-key rotation tells all but the last, and the flat 3D check the last, nor two
    // eyes one above the other by its name while "3D by file name" is on), its relief estimated by the headset itself;
    // not the preview of a 3D scene, which has its own button, nor a photo named like one while its head is read.
    // Greyed with its reason where the gate refuses; nothing with the AI features off (see reliefGateProvider).
    final isFlatPhoto =
        flatStereoState != null &&
        flatStereoState.hasValue &&
        flatStereo == null &&
        stackedPhoto == null &&
        (sceneState == null || (sceneState.hasValue && sceneXmp == null)) &&
        ref.watch(rotationModeProvider(asset)) != RotationMode.none;
    final reliefGate = isFlatPhoto ? ref.watch(reliefGateProvider) : ReliefGate.hidden;
    final reliefButton = reliefGate.visible
        ? AiReliefButton(
            gate: reliefGate,
            target: assetReliefTarget(ref, asset, open: (stereo) => _openStereoPhoto(context, ref, asset, stereo)),
            mode: ref.watch(appConfigProvider.select((config) => config.aiImmersive.questMode)),
          )
        : null;

    // "View on a big screen" on a Meta Quest: an ordinary photo or video, whole on a large flat screen of the immersive
    // viewer that the grips move and resize (an idea of Gaurav Mukherjee, gmfun/Immuch360 branch quest/flat-3d). A
    // photo once the reads above found it flat (the AI relief may show beside it, for its 3D), a video neither 360°
    // nor told 3D by its name; never a media shown as 360°, which keeps its own viewer
    final isFlatVideo = isHorizonOs && asset.isVideo && !hasPanoramaView && flatVideoFormat == null;
    final bigScreenButton = isFlatPhoto || isFlatVideo
        ? IconButton(
            key: const Key('immersive_big_screen'),
            icon: const Icon(Icons.fit_screen_rounded),
            tooltip: context.t.immersive_view_big_screen,
            onPressed: () => unawaited(_openBigScreen(context, ref, asset)),
          )
        : null;

    // Immuch360 Desktop: the window in full screen (lib/desktop/window/full_screen.dart)
    final fullScreenButton = CurrentPlatform.isDesktop ? const DesktopFullScreenButton() : null;
    // Immuch360 Desktop: the view modes of a photo of two eyes side by side (lib/desktop/ai/sbs_view_modes.dart)
    final sbsViewButton = CurrentPlatform.isDesktop ? DesktopSbsViewButton(asset: asset) : null;
    // Immuch360 Desktop: "Preview in 3D" of a photo carrying a 3D scene (lib/desktop/ai/scene_preview)
    final scenePreviewButton = CurrentPlatform.isDesktop ? DesktopScenePreviewButton(asset: asset) : null;

    // The one-key rotation: here on a computer, and in the read only mode of a phone, whose bottom row is hidden. A TV
    // has it in its bottom bar, a phone otherwise in the bottom row (see RotateAction).
    final hasTopRotate = CurrentPlatform.isDesktop || (ref.watch(readonlyModeProvider) && !ref.watch(tvModeProvider));
    final rotateButton = hasTopRotate && canRotateInViewer(ref, asset) ? ViewerRotateIconButton(asset: asset) : null;

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
      // Hidden, its buttons must not take the focus either: an arrow of a remote would land on an invisible button
      child: ExcludeFocus(
        excluding: opacity < 1.0,
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
                      // A TV shows the date and time of a photo at the bottom left instead (see ViewerBottomBar)
                      middle: showingDetails || (isTv && asset.isImage) ? null : ViewerDateTime(asset: asset),
                      trailing:
                          !showingDetails &&
                              (!isViewOnly ||
                                  panoramaButton != null ||
                                  spatialButton != null ||
                                  view3dButton != null ||
                                  sceneButton != null ||
                                  reliefButton != null ||
                                  bigScreenButton != null ||
                                  rotateButton != null ||
                                  fullScreenButton != null)
                          ? ImmichColorOverride(
                              color: Colors.white,
                              child: Focus(
                                focusNode: trailingFocusNode,
                                canRequestFocus: false,
                                skipTraversal: true,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ?view3dButton,
                                    ?sceneButton,
                                    ?reliefButton,
                                    ?bigScreenButton,
                                    ?panoramaButton,
                                    ?spatialButton,
                                    ?rotateButton,
                                    ?sbsViewButton,
                                    ?scenePreviewButton,
                                    ?fullScreenButton,
                                    if (!isViewOnly) ...(isInLockedView ? lockedViewActions : actions),
                                  ],
                                ),
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
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(60.0);
}

/// Opens [asset], an Apple spatial photo, a side by side photo, a photo for an AI relief or a photo that carries a 3D
/// scene as [stereo] describes it, in 3D in the immersive viewer (see [openStereoPhotoViewer]); a message says when it
/// could not open
Future<void> _openStereoPhoto(BuildContext context, WidgetRef ref, BaseAsset asset, StereoPhotoRequest stereo) async {
  // Read before the first await: the viewer may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorMessage = context.t.immersive_viewer_open_failed;
  final tiffMessage = context.t.tiff_cannot_decode;
  final stereoLabels = stereoPhotoViewerLabels(context.t);
  try {
    await openStereoPhotoViewer(ref, asset, stereo, stereoLabels: stereoLabels);
  } catch (error) {
    _log.warning('Could not open ${asset.name} in 3D: $error');
    // A TIFF of the headset that does not decode says so (see ImmersiveAssetResolver.resolveStereoPhoto)
    messenger?.showSnackBar(SnackBar(content: Text(error is TiffDecodeException ? tiffMessage : errorMessage)));
  }
}

/// Opens [asset], a flat 3D video packed as [format], on the flat video screen of the immersive viewer (see
/// [openFlatVideoViewer]); a message says when it could not open, or what to know about the file chosen
Future<void> _openFlatVideo(BuildContext context, WidgetRef ref, BaseAsset asset, FlatStereoFormat format) async {
  // Read before the first await: the viewer may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorMessage = context.t.immersive_viewer_open_failed;
  final stereoLabels = stereoPhotoViewerLabels(context.t);
  try {
    await openFlatVideoViewer(
      ref,
      asset,
      format,
      stereoLabels: stereoLabels,
      // Comes once the file is chosen, after the slow steps: the static translations do not need the viewer then
      onSourceNotice: (notice) =>
          messenger?.showSnackBar(SnackBar(content: Text(notice.message(StaticTranslations.instance)))),
    );
  } catch (error) {
    _log.warning('Could not open ${asset.name} in 3D: $error');
    messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
  }
}

/// Opens [asset], an ordinary photo or video, whole on the big screen of the immersive viewer of a Meta Quest (see
/// [openBigScreenPhoto] and [openBigScreenVideo]); a message says when it could not open, or what to know about the
/// file of a video
Future<void> _openBigScreen(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  // Read before the first await: the viewer may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorMessage = context.t.immersive_viewer_open_failed;
  final tiffMessage = context.t.tiff_cannot_decode;
  final stereoLabels = stereoPhotoViewerLabels(context.t);
  try {
    if (asset.isVideo) {
      await openBigScreenVideo(
        ref,
        asset,
        stereoLabels: stereoLabels,
        // Comes once the file is chosen, after the slow steps: the static translations do not need the viewer then
        onSourceNotice: (notice) =>
            messenger?.showSnackBar(SnackBar(content: Text(notice.message(StaticTranslations.instance)))),
      );
    } else {
      await openBigScreenPhoto(ref, asset, stereoLabels: stereoLabels);
    }
  } catch (error) {
    _log.warning('Could not open ${asset.name} on the big screen: $error');
    messenger?.showSnackBar(SnackBar(content: Text(error is TiffDecodeException ? tiffMessage : errorMessage)));
  }
}

class _AppBarBackButton extends ConsumerWidget {
  const _AppBarBackButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));
    // In the remote control layout the viewer's PopScope keeps the Back key of a remote for the bars while they have
    // the focus, which this button has when pressed with OK: it closes the viewer itself, not through maybePop
    final tvMode = ref.watch(tvModeProvider);
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: showingDetails ? context.colorScheme.surface : Colors.transparent,
        shape: const CircleBorder(),
        iconSize: 22,
        iconColor: showingDetails ? context.colorScheme.onSurface : Colors.white,
        padding: const EdgeInsets.all(10.0),
        elevation: showingDetails ? 4 : 0,
      ),
      onPressed: tvMode ? () => Navigator.of(context).pop() : context.maybePop,
      child: const Icon(Icons.arrow_back_rounded),
    );
  }
}
