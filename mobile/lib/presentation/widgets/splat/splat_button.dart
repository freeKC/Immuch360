// "Explore the splat scene" (lot S5): a Gaussian splat file of another tool opened in the immersive viewer of a Meta
// Quest 3 or 3S. The gate of the headset (splatGateOf, from the head of the file) offers it, or greys it with its
// reason from the moment the headset is known (spec 10.2 of the AI immersive design: never hidden); the viewer checks
// again on the file itself, with the free memory and the heat.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// The key of "Explore the splat scene"
const exploreSplatButtonKey = Key('splat_explore');

/// The key of the reason under a greyed button
const splatRefusalKey = Key('splat_refusal');

/// The reason a splat is not offered on this headset, as the button says it greyed
String splatRefusalText(Translations t, SplatGateVerdict verdict, String locale) => switch (verdict.refusal) {
  SplatRefusal.notInThisVersion => t.ai_immersive_unavailable_build,
  SplatRefusal.olderHeadset => t.splat_older_headset,
  SplatRefusal.notASplat => t.splat_not_splat,
  SplatRefusal.compressedPly => t.splat_compressed_ply,
  SplatRefusal.unsupportedPly => t.splat_unsupported_ply,
  SplatRefusal.newerSpz => t.splat_newer_spz,
  SplatRefusal.damaged => t.splat_damaged,
  SplatRefusal.tooLarge => t.splat_too_large(count: splatCountText(verdict.gaussians ?? 0, locale)),
  null => '',
};

/// What the head of a splat file says of it, as the page writes it: "452,451 gaussians, SPZ version 3", "19,469
/// gaussians, PLY, made with Postshot" (the tool only when a comment of the file names it)
String splatFileLine(Translations t, SplatHead head, String locale) {
  final count = splatCountText(head.gaussians, locale);
  return switch (head.format) {
    SplatFormat.spz => t.splat_spz_line(count: count, version: '${head.formatVersion}'),
    SplatFormat.ply when head.tool != null => t.splat_ply_tool_line(count: count, tool: head.tool!),
    SplatFormat.ply => t.splat_ply_line(count: count),
  };
}

/// The gate of the splat [probe] says, the file [name] of [fileBytes], on this headset with the settings of now; null
/// until the headset is read
SplatGateVerdict? splatVerdictOf(WidgetRef ref, SplatProbe probe, {required String name, required int fileBytes}) {
  final facts = ref.watch(reliefDeviceFactsProvider);
  if (facts.isLoading && !facts.hasValue && !facts.hasError) {
    return null;
  }
  return splatGateOf(
    probe: probe,
    name: name,
    fileBytes: fileBytes,
    largeSplats: ref.watch(appConfigProvider.select((config) => config.viewer.largeSplats)),
    flavor: ref.watch(appFlavorProvider),
    device: facts.valueOrNull?.device,
  );
}

/// See the top of this file: the splat whose head said [probe], the file [name] of [fileBytes], opened with [open]
class SplatButton extends ConsumerWidget {
  const SplatButton({super.key, required this.probe, required this.name, required this.fileBytes, required this.open});

  final SplatProbe probe;
  final String name;
  final int fileBytes;
  final Future<void> Function(GaussianSplatRequest request) open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nothing until the headset is read, so that a splat it cannot show is never offered first
    final verdict = splatVerdictOf(ref, probe, name: name, fileBytes: fileBytes);
    if (verdict == null) {
      return const SizedBox.shrink();
    }
    final request = verdict.request;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: exploreSplatButtonKey,
          icon: const Icon(Icons.view_in_ar_rounded),
          label: Text(context.t.splat_explore),
          onPressed: request == null ? null : () => unawaited(open(request)),
        ),
        if (request == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              splatRefusalText(context.t, verdict, locale),
              key: splatRefusalKey,
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
