// The 3D scene buttons of the 2D panel of the Meta Quest (design-final 2026-10-27, sections 3.5 and 9.2): "Explore
// the 3D scene" on a photo that carries one, in the viewer of the library and on the photo page of the shares, and
// "View the 3D scene" on an original that has one next to it on a share. Both open the photo that carries the scene in
// the immersive viewer with the volumetricScene request its packet makes; nothing of the AI is needed, nothing is
// downloaded but the file. A scene the gate of the headset refuses (sceneGateOf, read in the packet at the head of the
// file) keeps its button, greyed with the reason (spec 10.2); the viewer checks again on the scene itself.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/scene_gate.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';

/// The key of "Explore the 3D scene", on a photo that carries a scene
const exploreSceneButtonKey = Key('ai_immersive_explore_scene');

/// The key of "View the 3D scene", on an original that has a scene next to it
const viewSceneButtonKey = Key('ai_immersive_view_scene');

/// The reason a scene stays flat in this headset, as the button says it greyed
String sceneRefusalText(Translations t, SceneGateVerdict verdict) => switch (verdict.refusal) {
  SceneRefusal.newerVersion => t.ai_immersive_newer_version,
  SceneRefusal.notOurs => t.ai_immersive_scene_not_ours,
  SceneRefusal.missing => t.ai_immersive_scene_missing,
  SceneRefusal.tooHeavy => switch ((verdict.triangles, verdict.maxTriangles)) {
    (final int triangles, final int max) => t.ai_immersive_scene_too_heavy(triangles: triangles, max: max),
    _ => t.ai_immersive_scene_too_heavy_plain,
  },
  null => '',
};

/// See the top of this file: the scene whose packet is [xmp], in a file of [fileSize] bytes when known, opened with
/// [open]; [fromOriginal] for "View the 3D scene" on the original, else "Explore the 3D scene" on the photo itself.
class AiSceneButton extends ConsumerWidget {
  const AiSceneButton({super.key, required this.xmp, required this.open, this.fromOriginal = false, this.fileSize});

  final SceneXmp xmp;
  final Future<void> Function(StereoPhotoRequest request) open;
  final bool fromOriginal;
  final int? fileSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The headset, for its caps: those of the Quest 3 until it is read, the viewer checking again
    final device = ref.watch(reliefDeviceFactsProvider).valueOrNull?.device;
    final verdict = sceneGateOf(xmp, device: device, fileSize: fileSize);
    final request = verdict.request;
    final t = context.t;
    return IconButton(
      key: fromOriginal ? viewSceneButtonKey : exploreSceneButtonKey,
      icon: const Icon(Icons.threed_rotation_rounded),
      tooltip: request == null
          ? sceneRefusalText(t, verdict)
          : fromOriginal
          ? t.ai_immersive_view_scene
          : t.ai_immersive_explore_scene,
      onPressed: request == null ? null : () => unawaited(open(StereoPhotoRequest.scene(request))),
    );
  }
}
