// The gate of the Gaussian splats on the Meta Quest (lot S5), on the Dart side, and below it the gate of the splat
// viewer of the computers, phones and tablets (splatViewerGateOf). The headset's: whether "Explore the splat scene" is
// offered, or greyed with its reason, from the head of the file alone (spec 10.2 of the AI immersive design: a refused
// button stays visible, greyed with its reason). The splat module of the Meta Spatial SDK runs on the Quest 3 and 3S
// only and is in the APK of the quest flavour only; the count the headset shows is 50 000 gaussians until a measure
// in the headset, 150 000 with Large splats (the advice of the SDK), and a splat that holds more is reduced in the
// headset up to 4 million gaussians and 1 GiB. The splat module reads SPZ version 2 only and aborts the app on any
// other (measured on a Quest 3 on 31 October 2026): the headset writes every SPZ again as version 2, versions 2 and 4
// included (a version 2 cut or short of its data aborts it too; version 4 is ZSTD, which the quest flavour
// decompresses, FreeKC's report of 1 November 2026). The immersive viewer checks again (SplatGate.kt), with the free
// memory and the heat of the headset.

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

  /// Beyond what the headset reduces: "Too large for this headset (N gaussians)"; on a computer, a phone or a tablet:
  /// "Too large for this device (N gaussians)"
  tooLarge,

  /// The splat viewer of the computers, phones and tablets: an SPZ of version 4 above the cap, which only the page
  /// could reduce (lot SV8)
  v4AboveCap,

  /// The splat viewer of the computers, phones and tablets: harmonics of degree 4, which Spark does not draw
  degree4,
}

/// The kinds of device the splats open on: the headset (the immersive viewer of the Meta Spatial SDK), a phone or a
/// tablet, a computer (the splat viewer's page, lot SV1 to SV6)
enum SplatDeviceClass { quest, phone, computer }

/// Phones and tablets show this many gaussians whole (decision D1 of the splat viewer plan, as recommended until
/// FreeKC answers: what Brush and Make a splat scene write shows whole), and [splatPhoneLargeGaussians] with Large splats
const splatPhoneGaussians = 150000;
const splatPhoneLargeGaussians = 500000;

/// Computers show this many whole, Large splats or not
const splatComputerGaussians = 1000000;

/// The most gaussians a [device] shows whole, the rest reduced away
int splatViewerCapOf(SplatDeviceClass device, {required bool largeSplats}) => switch (device) {
  SplatDeviceClass.quest => largeSplats ? splatLargeGaussians : splatSafeGaussians,
  SplatDeviceClass.phone => largeSplats ? splatPhoneLargeGaussians : splatPhoneGaussians,
  SplatDeviceClass.computer => splatComputerGaussians,
};

/// The gate of the splat viewer of the computers, phones and tablets (plan section 6): the file, then the count. Every
/// SPZ version and PLY opens as it is under the cap (Spark reads them); above it the strongest gaussians are kept
/// (splat_reducer.dart) up to 4 million gaussians and 1 GiB, an SPZ of version 4 excepted until the page reduces it.
/// Harmonics of degree 4 are refused: Spark draws degrees 0 to 3. The headset keeps [splatGateOf].
SplatGateVerdict splatViewerGateOf({
  required SplatProbe probe,
  required String name,
  required int fileBytes,
  required bool largeSplats,
  required SplatDeviceClass device,
}) {
  if (device == SplatDeviceClass.quest) {
    return const SplatGateVerdict.refused(SplatRefusal.notInThisVersion);
  }
  final SplatHead head;
  switch (probe) {
    case SplatRefused(:final problem):
      return SplatGateVerdict.refused(splatRefusalOf(problem));
    case final SplatHead read:
      head = read;
  }
  if (head.shDegree > 3) {
    return const SplatGateVerdict.refused(SplatRefusal.degree4);
  }
  final cap = splatViewerCapOf(device, largeSplats: largeSplats);
  if (head.gaussians > cap) {
    if (head.gaussians > splatMaxReducibleGaussians || fileBytes > splatMaxReducibleBytes) {
      return SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: head.gaussians);
    }
    if (head.isZstd) {
      return SplatGateVerdict.refused(SplatRefusal.v4AboveCap, gaussians: head.gaussians);
    }
  }
  return SplatGateVerdict.open(
    GaussianSplatRequest(
      format: head.format.json,
      formatVersion: head.formatVersion,
      gaussians: head.gaussians,
      shDegree: head.shDegree,
      fileBytes: fileBytes,
      maxGaussians: cap,
      tool: head.tool,
      name: name,
    ),
  );
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
/// again), in a build that offers the splats or not ([inThisBuild], false where SplatBuild.kt hides them). In the order
/// of SplatGate.kt: the flavour and the build, the headset, the file, the count. Every version of SPZ opens: the
/// headset writes it again as version 2.
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
  if (head.gaussians > most && (head.gaussians > splatMaxReducibleGaussians || fileBytes > splatMaxReducibleBytes)) {
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
