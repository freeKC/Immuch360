// The gate of the Gaussian splats on the Meta Quest (lot S5), on the Dart side: whether "Explore the splat scene" is
// offered, or greyed with its reason, from the head of the file alone (spec 10.2 of the AI immersive design: a refused
// button stays visible, greyed with its reason). The splat module of the Meta Spatial SDK runs on the Quest 3 and 3S
// only and is in the APK of the quest flavour only; the count the headset shows is 50 000 gaussians until a measure
// in the headset, 150 000 with Large splats (the advice of the SDK), and a splat that holds more is reduced in the
// headset up to 4 million gaussians and 1 GiB, a version 4 SPZ excepted. The immersive viewer checks again
// (SplatGate.kt), with the free memory and the heat of the headset.

import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The count of gaussians until a measure in the headset (decision D7 of design-final 2026-10-27)
const splatSafeGaussians = 50000;

/// The advice of the Meta Spatial SDK, the most Large splats shows
const splatLargeGaussians = 150000;

/// The most gaussians and bytes the headset reduces
const splatMaxReducibleGaussians = 4000000;
const splatMaxReducibleBytes = 1 << 30;

/// Build.DEVICE of the Quest 2 and the Quest Pro, which the splat module does not run on
const splatOlderDevices = {'hollywood', 'seacliff'};

/// The flavour of the APK of the headset, the only one with the splat module
const splatQuestFlavor = 'quest';

/// Why a splat is not offered
enum SplatRefusal {
  /// The APK of the phone flavour, or the build of the Meta Horizon Store, which hides the splats (SplatBuild.kt):
  /// "Not in this version of the app"
  notInThisVersion,

  /// A Quest 2 or a Quest Pro: "Gaussian splats need a Meta Quest 3 or 3S"
  olderHeadset,
  notASplat,
  compressedPly,
  unsupportedPly,
  newerSpz,
  damaged,

  /// Beyond what the headset reduces: "Too large for this headset (N gaussians)"
  tooLarge,
}

/// What the gate says of a splat: open with the [request] for the viewer, or refused with its [refusal] (and the
/// [gaussians] of a splat too large)
class SplatGateVerdict {
  const SplatGateVerdict.open(GaussianSplatRequest this.request) : refusal = null, gaussians = null;

  const SplatGateVerdict.refused(SplatRefusal this.refusal, {this.gaussians}) : request = null;

  final GaussianSplatRequest? request;
  final SplatRefusal? refusal;
  final int? gaussians;

  bool get isOpen => request != null;

  @override
  bool operator ==(Object other) =>
      other is SplatGateVerdict && other.request == request && other.refusal == refusal && other.gaussians == gaussians;

  @override
  int get hashCode => Object.hash(request, refusal, gaussians);

  @override
  String toString() =>
      isOpen ? 'SplatGateVerdict.open(${request!.toJsonString()})' : 'SplatGateVerdict.refused($refusal)';
}

/// The refusal of a file the probe refused
SplatRefusal splatRefusalOf(SplatFileProblem problem) => switch (problem) {
  SplatFileProblem.notASplat => SplatRefusal.notASplat,
  SplatFileProblem.compressedPly => SplatRefusal.compressedPly,
  SplatFileProblem.unsupportedPly => SplatRefusal.unsupportedPly,
  SplatFileProblem.newerSpz => SplatRefusal.newerSpz,
  SplatFileProblem.damaged => SplatRefusal.damaged,
};

/// The gate of the splat [probe] says, the file [name] of [fileBytes], with Large splats on or not ([largeSplats]),
/// in the APK of [flavor] on the headset [device] (null when it could not be read: offered, the viewer checking
/// again), in a build that offers the splats or not ([inThisBuild], false in the store build). In the order of
/// SplatGate.kt: the flavour and the build, the headset, the file, the count.
SplatGateVerdict splatGateOf({
  required SplatProbe probe,
  required String name,
  required int fileBytes,
  required bool largeSplats,
  required String? flavor,
  required String? device,
  required bool inThisBuild,
}) {
  if (flavor != splatQuestFlavor || !inThisBuild) {
    return const SplatGateVerdict.refused(SplatRefusal.notInThisVersion);
  }
  if (splatOlderDevices.contains(device)) {
    return const SplatGateVerdict.refused(SplatRefusal.olderHeadset);
  }
  final SplatHead head;
  switch (probe) {
    case SplatRefused(:final problem):
      return SplatGateVerdict.refused(splatRefusalOf(problem));
    case final SplatHead read:
      head = read;
  }
  final most = largeSplats ? splatLargeGaussians : splatSafeGaussians;
  if (head.gaussians > most &&
      (head.isZstd || head.gaussians > splatMaxReducibleGaussians || fileBytes > splatMaxReducibleBytes)) {
    return SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: head.gaussians);
  }
  return SplatGateVerdict.open(
    GaussianSplatRequest(
      format: head.format.json,
      formatVersion: head.formatVersion,
      gaussians: head.gaussians,
      shDegree: head.shDegree,
      fileBytes: fileBytes,
      maxGaussians: most,
      tool: head.tool,
      name: name,
    ),
  );
}
