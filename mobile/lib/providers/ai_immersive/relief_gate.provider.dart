// The gate of the AI relief on the Meta Quest (design-final 2026-10-26, section 3.5): whether the "AI relief" button
// of the 2D panel shows, and whether it is offered or greyed with its reason. The relief needs the LiteRT engine of
// the quest flavour, about 300 MB of memory and a GPU that was tried: the Quest 3 and 3S are offered; the Quest 2 and
// Pro are greyed, "not tested on this headset yet", until the untested switch of the advanced settings is on; a device
// that sees under 5 GiB (6 GB physical) is refused; the APK of the phone flavour installed on a headset says it is not
// in this version of the app. A refused button stays visible, greyed with its reason, never hidden (spec 10.2). Off
// Horizon OS, or with the AI features off, there is no button at all.
//
// The flavour is appFlavor, the --flavor of the build (build.sh on ai1 and immuch360-release.yml build the headset APK
// with --flavor quest). The device is Build.DEVICE and the memory ActivityManager.MemoryInfo.totalMem, both read by
// device_info_plus. The immersive viewer checks again when it gets the request.

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ReliefGate');

/// The flavour of the headset APK, the only one that carries LiteRT
const questFlavor = 'quest';

/// Build.DEVICE of the headsets the relief was made for: Quest 3 and Quest 3S
const reliefQuestHeadsets = {'eureka', 'panther'};

/// Build.DEVICE of the older headsets, greyed until "AI relief on Quest 2 and Quest Pro (untested)" is on: Quest 2 and
/// Quest Pro
const reliefOlderHeadsets = {'hollywood', 'seacliff'};

/// The least memory Android must see for the relief: 5 GiB, what a device of 6 GB physical shows once the kernel took
/// its part
const reliefMinMemoryMiB = 5 * 1024;

/// Why the relief is refused on this device: the button stays, greyed with this reason
enum ReliefRefusal {
  /// The APK of the phone flavour, without the LiteRT engine: "Not in this version of the app"
  build,

  /// Under 6 GB of physical memory: "Not enough memory"
  memory,

  /// A Quest 2 or a Quest Pro while the untested switch is off: "Not tested on this headset yet"
  headset,
}

/// What the "AI relief" button does here: hidden, offered, or shown greyed with its [refusal]
class ReliefGate {
  const ReliefGate._({required this.visible, this.slowHeadset = false}) : refusal = null;

  /// Greyed with [refusal]
  const ReliefGate.refused(ReliefRefusal this.refusal) : visible = true, slowHeadset = false;

  /// No button: not a Meta Quest, the AI features off, or the device not read yet
  static const hidden = ReliefGate._(visible: false);

  static const offered = ReliefGate._(visible: true);

  /// Offered on a Quest 2 or a Quest Pro by the untested switch: each relief starts with a passing warning that it may
  /// take several seconds
  static const offeredSlow = ReliefGate._(visible: true, slowHeadset: true);

  final bool visible;
  final ReliefRefusal? refusal;
  final bool slowHeadset;

  bool get isOffered => visible && refusal == null;

  @override
  bool operator ==(Object other) =>
      other is ReliefGate && other.visible == visible && other.refusal == refusal && other.slowHeadset == slowHeadset;

  @override
  int get hashCode => Object.hash(visible, refusal, slowHeadset);

  @override
  String toString() => 'ReliefGate(visible: $visible, refusal: $refusal, slowHeadset: $slowHeadset)';
}

/// What the gate reads of the device: its Build.DEVICE and the memory Android sees, in MiB
class ReliefDeviceFacts {
  const ReliefDeviceFacts({required this.device, required this.memoryMiB});

  final String device;
  final int memoryMiB;

  @override
  String toString() => 'ReliefDeviceFacts($device, $memoryMiB MiB)';
}

/// The gate for a device on Horizon OS ([horizonOs]) with the AI features [enabled], the untested switch
/// [olderHeadsets], the build [flavor] and the [facts] of the device (null when they could not be read: offered, the
/// immersive viewer checking again). In this order: the flavour, which nothing else can change, then the memory, then
/// the headset.
ReliefGate reliefGateOf({
  required bool horizonOs,
  required bool enabled,
  required bool olderHeadsets,
  required String? flavor,
  required ReliefDeviceFacts? facts,
}) {
  if (!horizonOs || !enabled) {
    return ReliefGate.hidden;
  }
  if (flavor != questFlavor) {
    return const ReliefGate.refused(ReliefRefusal.build);
  }
  if (facts == null) {
    return ReliefGate.offered;
  }
  if (facts.memoryMiB < reliefMinMemoryMiB) {
    return const ReliefGate.refused(ReliefRefusal.memory);
  }
  if (reliefOlderHeadsets.contains(facts.device)) {
    return olderHeadsets ? ReliefGate.offeredSlow : const ReliefGate.refused(ReliefRefusal.headset);
  }
  return ReliefGate.offered;
}

/// The --flavor of the build, null for a build without one (the tests). Tests replace it.
final appFlavorProvider = Provider<String?>((_) => appFlavor);

/// The device and its memory, read once; only on Horizon OS (see [reliefGateProvider]). Tests replace it.
final reliefDeviceFactsProvider = FutureProvider<ReliefDeviceFacts?>((ref) async {
  final info = await DeviceInfoPlugin().androidInfo;
  return ReliefDeviceFacts(device: info.device, memoryMiB: info.physicalRamSize);
});

// A headset the relief was not made for, offered by its memory: said once per run in the log of the app
bool _otherHeadsetLogged = false;

/// The gate of the "AI relief" button on this device (see [reliefGateOf]). The device is read only on Horizon OS, with
/// the AI features on and the quest flavour; hidden until then.
final reliefGateProvider = Provider.autoDispose<ReliefGate>((ref) {
  final horizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
  final config = ref.watch(appConfigProvider.select((config) => config.aiImmersive));
  final flavor = ref.watch(appFlavorProvider);
  ReliefGate gate(ReliefDeviceFacts? facts) => reliefGateOf(
    horizonOs: horizonOs,
    enabled: config.enabled,
    olderHeadsets: config.olderHeadsets,
    flavor: flavor,
    facts: facts,
  );
  if (!horizonOs || !config.enabled || flavor != questFlavor) {
    return gate(null);
  }
  final facts = ref.watch(reliefDeviceFactsProvider);
  if (facts.hasError) {
    _log.warning('Could not read the device for the AI relief: ${facts.error}');
    return gate(null);
  }
  if (!facts.hasValue) {
    return ReliefGate.hidden;
  }
  final read = facts.requireValue;
  if (read != null &&
      !_otherHeadsetLogged &&
      !reliefQuestHeadsets.contains(read.device) &&
      !reliefOlderHeadsets.contains(read.device)) {
    _otherHeadsetLogged = true;
    _log.info('AI relief on a headset it was not made for: $read');
  }
  return gate(read);
}, dependencies: [isHorizonOsProvider, appConfigProvider, appFlavorProvider, reliefDeviceFactsProvider]);
