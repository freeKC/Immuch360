// The controls of the one-key rotation outside the bottom row of the viewer (see RotateAction): the button of the top
// bar on a computer and in the read only mode of a phone, the button of a TV, and the thin bar that shows while the
// server saves a rotation. The keys are read by the viewer itself (see isRemoteRotateClockwise).

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';

/// Whether [asset] turns with the one-key rotation, see [rotationModeProvider]
bool canRotateInViewer(WidgetRef ref, BaseAsset asset) => ref.watch(rotationModeProvider(asset)) != RotationMode.none;

/// The rotation in the top bar of the viewer: a press turns [asset] 90° clockwise, a long press counter clockwise.
/// Build it only for an asset that turns ([canRotateInViewer]).
class ViewerRotateIconButton extends ConsumerWidget {
  const ViewerRotateIconButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: () => rotateAssetFromWidget(ref, asset, -1),
      child: IconButton(
        key: const Key('viewer_rotate_button'),
        icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
        tooltip: context.t.editor_rotate_right,
        onPressed: () => rotateAssetFromWidget(ref, asset, 1),
      ),
    );
  }
}

/// The rotation in the bottom bar of a TV, on the right of the OCR toggle: OK from the photo never lands on it, so that
/// a double OK on a household TV cannot turn a photo, on the server for one of the user. Right from the OCR toggle (or
/// Down from the photo when the bar has nothing else) reaches it, then each OK turns the photo again and the focus
/// stays. The yellow and blue keys of the remote turn it from anywhere.
class TvRotateButton extends ConsumerWidget {
  const TvRotateButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = context.t.rotate;
    // The right margin of the OCR toggle, whose row ends with this button
    return Padding(
      padding: const EdgeInsets.only(right: 32, bottom: 8),
      child: RemoteFocusable(
        key: const Key('tv_rotate_button'),
        onTap: () => rotateAssetFromWidget(ref, asset, 1),
        onLongPress: () => rotateAssetFromWidget(ref, asset, -1),
        child: Semantics(
          button: true,
          label: context.t.editor_rotate_right,
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.rotate_90_degrees_cw_rounded, size: 22, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [node] is the focus of a [TvRotateButton], where OK from the photo never lands (see AssetViewer)
bool isTvRotateFocus(FocusNode node) => node.context?.findAncestorWidgetOfExactType<TvRotateButton>() != null;

/// A thin bar while the server saves a rotation of [asset] and makes its turned picture; nothing otherwise
class RotationProgressBar extends ConsumerWidget {
  const RotationProgressBar({super.key, required this.asset});

  final BaseAsset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remoteId = asset is RemoteAsset ? asset!.remoteId : null;
    final saving = remoteId != null && ref.watch(rotationSavingProvider(remoteId));
    return AnimatedSwitcher(
      duration: Durations.short2,
      child: saving
          ? LinearProgressIndicator(minHeight: 2, semanticsLabel: context.t.rotate_saving)
          : const SizedBox(height: 2),
    );
  }
}
