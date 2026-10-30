import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/actions/rotate.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/upload.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/add_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_toggle_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/rotate_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_date_time.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';
import 'package:immich_ui/immich_ui.dart';

// Resolved here rather than as an ActionColumnButton so a hidden restore
// takes no slot in the spaceEvenly row below.
List<Widget> _actionColumnButtons(BuildContext context, WidgetRef ref, List<ActionBuilder> actions) => actions
    .map((a) => a.create(context, ref))
    .nonNulls
    .map<ImmichColumnButton>(
      (item) => .new(icon: item.icon, label: item.label, onPressed: item.onAction, onLongPress: item.onSecondaryAction),
    )
    .toList(growable: false);

/// The date and time of a photo on a TV stand out over the photo as the controls of a video do (see VideoControls)
const _tvDateTimeShadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

class ViewerBottomBar extends ConsumerWidget {
  const ViewerBottomBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    // The read only mode, or a TV, where the app is a viewer: no share, upload, edit, add or delete
    final isViewOnly = ref.watch(viewOnlyProvider);
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final isInLockedView = ref.watch(inLockedViewProvider);
    final isInTrash = ref.watch(timelineServiceProvider).origin == TimelineOrigin.trash;

    final originalTheme = context.themeData;
    final tvMode = ref.watch(tvModeProvider);
    // A TV hides the row of actions: its rotation sits on the right of the OCR toggle, never where OK from the photo
    // lands (see AssetViewer), so that a double OK cannot turn a photo
    final tvRotate = tvMode && !isInTrash && canRotateInViewer(ref, asset);
    // A TV shows the date and time of a photo on the left of that row rather than over the top centre of the photo
    // (see ViewerTopAppBar), with "Show photo date and time" on
    final tvDateTime =
        tvMode && asset.isImage && ref.watch(appConfigProvider.select((config) => config.viewer.tvShowDateTime));
    // The text boxes are not drawn over a photo turned on screen (see AssetPage)
    final showOcr = asset.isImage && ref.watch(displayQuarterTurnsProvider(asset)) == 0;

    final actions = <Widget>[
      ..._actionColumnButtons(context, ref, const [RestoreAction(source: .viewer), ShareAction(source: .viewer)]),

      if (!isInLockedView) ...[
        if (!isInTrash) ...[
          ..._actionColumnButtons(context, ref, [
            const UploadAction(source: .viewer, showProgress: true),
            // A computer has the rotation in the top bar (ViewerTopAppBar)
            if (!CurrentPlatform.isDesktop) const RotateAction(source: .viewer),
            const EditAssetAction(source: .viewer),
          ]),
          if (asset.hasRemote) ImmichColorOverride(color: null, child: AddActionButton(originalTheme: originalTheme)),
        ],
        ..._actionColumnButtons(context, ref, const [DeleteAction(source: .viewer)]),
      ],
    ];

    return AnimatedSwitcher(
      duration: Durations.short4,
      child: showingDetails
          ? const SizedBox.shrink()
          : Theme(
              data: context.themeData.copyWith(
                iconTheme: const IconThemeData(size: ImmichIconSize.md, color: Colors.white),
                textTheme: context.themeData.textTheme.copyWith(
                  labelLarge: context.themeData.textTheme.labelLarge?.copyWith(color: Colors.white),
                ),
              ),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black45, Colors.black12, Colors.transparent],
                            stops: [0.0, 0.7, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // A TV: the date and time of a photo on the left, the OCR toggle on the right, then
                          // Rotate on its right, one Right away. The row spans the bar, so that the bar and its shade
                          // span the screen as with the row of a phone. The date takes no focus.
                          if (tvRotate || tvDateTime)
                            Row(
                              children: [
                                if (tvDateTime)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                                      child: Align(
                                        alignment: AlignmentDirectional.centerStart,
                                        child: ViewerDateTime(
                                          key: const Key('viewer_tv_date_time'),
                                          asset: asset,
                                          alignLeft: true,
                                          shadows: _tvDateTimeShadows,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                if (showOcr) OcrToggleButton(asset: asset),
                                if (tvRotate) TvRotateButton(asset: asset),
                              ],
                            )
                          else if (showOcr)
                            OcrToggleButton(asset: asset),
                          if (asset.isVideo) VideoControls(videoPlayerName: asset.id),
                          if (!isViewOnly)
                            ImmichColorOverride(
                              color: Colors.white,
                              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: actions),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
