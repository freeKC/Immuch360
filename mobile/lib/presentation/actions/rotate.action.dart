import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';

/// The one-key rotation in the bottom row of the viewer (phones, tablets, the Meta Quest window): a press turns the
/// photo 90° clockwise, a long press counter clockwise, on the server or on this device as its mode says (see
/// [rotationModeProvider]). Absent for anything that does not turn: videos, and every 360°, 180° or 3D photo.
///
/// Its actions return at once, the request following later (see ViewRotationController): the column button disables
/// itself while an action runs, which would swallow quick presses and drop the focus of a remote.
class RotateAction extends AssetActionBuilder {
  const RotateAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetsActionProvider(source)).singleOrNull;
    if (asset == null || ref.watch(rotationModeProvider(asset)) == RotationMode.none) {
      return null;
    }
    return .new(
      icon: Icons.rotate_90_degrees_cw_rounded,
      label: context.t.rotate,
      onAction: () => _rotate(ref, 1),
      onSecondaryAction: () => _rotate(ref, -1),
    );
  }

  void _rotate(WidgetRef ref, int delta) {
    final asset = ref.read(assetsActionProvider(source)).singleOrNull;
    if (asset != null) {
      rotateAssetFromWidget(ref, asset, delta);
    }
  }
}
