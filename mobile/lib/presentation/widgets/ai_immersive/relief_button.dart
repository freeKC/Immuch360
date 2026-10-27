// The "AI relief" button of the 2D panel of the Meta Quest (design-final 2026-10-26, sections 3.5 and 5): next to the
// 3D buttons of a flat photo, in the viewer of the library and on the photo page of the shares. It asks the immersive
// viewer to show the photo with a relief estimated by AI, which the headset computes itself (lots A8a, A8b, A9a).
//
// Pressed, it installs the depth model first when it is missing (the install sheet of lot A3b: 99.5 MB, its licence,
// nothing downloaded before Download), then sends the depthRelief request: the model file on the headset, the key of
// the relief cache from who the photo is and the quarter turns the user sees it with. Refused by the gate (see
// reliefGateProvider), it stays visible, greyed with its reason. On a Quest 2 or Pro allowed by the untested switch, a
// passing message says that the relief can take several seconds there.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiReliefButton');

/// The components the relief of the headset needs: the depth model of the Quest. Tests replace it.
final reliefComponentsProvider = Provider<List<AiComponent>>((_) => aiComponentsFor(AiPlatform.questArm64));

/// The key of the button, for the tests and the focus of a remote
const aiReliefButtonKey = Key('ai_immersive_view_relief');

/// The reason a refused relief is greyed with
String reliefRefusalText(Translations t, ReliefRefusal refusal) => switch (refusal) {
  ReliefRefusal.build => t.ai_immersive_unavailable_build,
  ReliefRefusal.memory => t.ai_immersive_unavailable_memory,
  ReliefRefusal.headset => t.ai_immersive_unavailable_headset,
};

/// What the button needs of the photo it stands next to, asked at the press
class ReliefTarget {
  const ReliefTarget({required this.identity, required this.quarterTurns, required this.open});

  /// Who the photo is for the relief cache (see reliefIdentityOfAsset and reliefIdentityOfShareFile)
  final Future<String> Function() identity;

  /// The quarter turns clockwise the user sees the photo with, from its unedited file
  final Future<int> Function() quarterTurns;

  /// Opens the photo on the stereo quad of the immersive viewer with [request]
  final Future<void> Function(StereoPhotoRequest request) open;
}

/// The quarter turns clockwise [asset] is seen with in the viewer, from its unedited file, which the immersive viewer
/// reads: the rotation of its edits on the server, then the turns the viewer draws on top of the picture (kept on this
/// device, or those of a rotation being saved). A crop or a mirror made in Immich is not applied.
Future<int> reliefQuarterTurnsOfAsset(WidgetRef ref, BaseAsset asset) async {
  // Read before the first await: the viewer may be gone by then
  final drawn = ref.read(displayQuarterTurnsProvider(asset));
  final server = ref.read(viewRotationServerProvider);
  var edits = const <AssetEdit>[];
  if (asset is RemoteAsset && asset.isEdited) {
    try {
      edits = await server.edits(asset.id);
    } catch (error) {
      _log.warning('No edits of ${asset.name} for its relief: $error');
    }
  }
  return normalizeQuarterTurns(quarterTurnsOfEdits(edits) + drawn);
}

/// The [ReliefTarget] of an asset of the library: its checksum, else the SHA-1 of its file on the device; the turns
/// it is seen with (see [reliefQuarterTurnsOfAsset]); and [open], which shows it on the stereo quad
ReliefTarget assetReliefTarget(
  WidgetRef ref,
  BaseAsset asset, {
  required Future<void> Function(StereoPhotoRequest request) open,
}) {
  final storage = ref.read(storageRepositoryProvider);
  return ReliefTarget(
    identity: () => reliefIdentityOfAsset(
      asset,
      file: () async {
        final localId = asset.localId;
        return localId == null ? null : storage.getFileForAsset(localId);
      },
    ),
    quarterTurns: () => reliefQuarterTurnsOfAsset(ref, asset),
    open: open,
  );
}

/// See the top of this file. [gate] says whether it is offered or greyed; a hidden gate shows nothing.
class AiReliefButton extends ConsumerStatefulWidget {
  const AiReliefButton({super.key, required this.gate, required this.target});

  final ReliefGate gate;
  final ReliefTarget target;

  @override
  ConsumerState<AiReliefButton> createState() => _AiReliefButtonState();
}

class _AiReliefButtonState extends ConsumerState<AiReliefButton> {
  /// From the press until the immersive viewer was asked: a second press does nothing meanwhile
  bool _busy = false;

  Future<void> _press() async {
    // Read before the first await: the panel may be gone by then
    final t = context.t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final service = ref.read(aiComponentsServiceProvider);
    final components = ref.read(reliefComponentsProvider);
    final model = components.firstWhere((component) => component.kind == AiComponentKind.model);
    setState(() => _busy = true);
    try {
      if (widget.gate.slowHeadset) {
        messenger?.showSnackBar(SnackBar(content: Text(t.ai_immersive_older_headsets_warning)));
      }
      var file = await service.verifiedFile(model);
      if (file == null) {
        // Missing, being downloaded, or damaged: the install sheet lists what is not installed and intact
        if (!mounted) {
          return;
        }
        final installed = await showAiInstallSheet(context, aiMissingComponents(service, components));
        if (!installed) {
          return;
        }
        file = await service.verifiedFile(model);
      }
      if (file == null) {
        final damaged = service.statusOf(model).state == AiComponentState.damaged;
        messenger?.showSnackBar(
          SnackBar(content: Text(damaged ? t.ai_immersive_unavailable_damaged : t.ai_immersive_unavailable_missing)),
        );
        return;
      }
      // The target reads the providers and the context of the viewer it belongs to: still there as long as this
      // button is
      if (!mounted) {
        return;
      }
      final quarterTurns = await widget.target.quarterTurns();
      final identity = await widget.target.identity();
      final request = questReliefRequest(
        modelPath: file.path,
        model: model,
        identity: identity,
        quarterTurns: quarterTurns,
      );
      if (!mounted) {
        return;
      }
      _log.info('AI relief of key ${request.cacheKey}, ${request.quarterTurns} quarter turns');
      await widget.target.open(StereoPhotoRequest.relief(request));
    } catch (error, stack) {
      _log.warning('Could not ask for the AI relief', error, stack);
      messenger?.showSnackBar(SnackBar(content: Text(t.immersive_viewer_open_failed)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = widget.gate;
    if (!gate.visible) {
      return const SizedBox.shrink();
    }
    final refusal = gate.refusal;
    return IconButton(
      key: aiReliefButtonKey,
      icon: const Icon(Icons.auto_awesome_rounded),
      tooltip: refusal == null ? context.t.ai_immersive_view_relief : reliefRefusalText(context.t, refusal),
      onPressed: refusal != null || _busy ? null : () => unawaited(_press()),
    );
  }
}
