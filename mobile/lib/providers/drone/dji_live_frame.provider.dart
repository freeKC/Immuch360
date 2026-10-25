// The values a pilot reads on the DJI live video, ten times a second (p2/design-final-2026-10-24.md, 3.4), the
// pilot's choices about the obstacle ring (p2/design-obstacle-ring-2026-10-25.md, 6), and a headset's choice of delay.
// The frame is kept apart from the link's state, so that a number that moves with the flight redraws its own cell and
// nothing else: the page and the picture are never rebuilt by a value. The ring is information for the pilot: nothing
// here reaches the remote or the drone.

import 'dart:math' as math;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiLiveFrame');

/// The last frame of values: from flightChanged while a screen with the picture is in front, and from every snapshot
class DjiLiveFrameNotifier extends Notifier<DjiLiveFrame?> {
  @override
  DjiLiveFrame? build() => null;

  /// A newer frame replaces the one shown; an older one (a snapshot built before the last event) is dropped
  void offer(DjiLiveFrame? frame) {
    if (frame == null) {
      return;
    }
    final current = state;
    if (current != null && frame.atMs < current.atMs) {
      return;
    }
    state = frame;
  }

  /// A new session: nothing of the last one is drawn before its first frame
  void clear() => state = null;
}

final djiLiveFrameProvider = NotifierProvider<DjiLiveFrameNotifier, DjiLiveFrame?>(DjiLiveFrameNotifier.new);

/// "Glow from" and "Strong glow from" when never set, in centimetres: FreeKC's example
const djiObstacleDefaultFarCm = 300;
const djiObstacleDefaultNearCm = 100;

/// The steppers of Advanced: "Glow from" 1.0 to 6.0 m by 0.5, "Strong glow from" 0.25 to 2.5 m by 0.25, at least 0.5 m
/// under "Glow from". Down to 1.0 m for a room: in the indoor hover of 25 October every reading was 0.29 to 1.44 m
/// (p2/review-obstacle-ring-2026-10-25.md, major 2).
const djiObstacleFarMinCm = 100;
const djiObstacleFarMaxCm = 600;
const djiObstacleFarStepCm = 50;
const djiObstacleNearMinCm = 25;
const djiObstacleNearMaxCm = 250;
const djiObstacleNearStepCm = 25;
const djiObstacleGapCm = 50;

/// The two distances within their steppers, "Strong glow from" at least [djiObstacleGapCm] under "Glow from"
(int, int) djiObstacleDistancesCm(int farCm, int nearCm) {
  final far = farCm.clamp(djiObstacleFarMinCm, djiObstacleFarMaxCm);
  final nearMax = math.min(djiObstacleNearMaxCm, far - djiObstacleGapCm);
  final near = nearCm.clamp(djiObstacleNearMinCm, nearMax);
  return (far, near);
}

/// What the pilot chose for the obstacle ring (p2/design-obstacle-ring-2026-10-25.md, 6). On a phone, all of it in
/// Advanced. On a TV or a headset, whether it is offered, the distances and the side come from the phone's record; only
/// the sound, the number and the sample are their own.
class DjiObstacleSettings {
  const DjiObstacleSettings({
    this.alertOn = false,
    this.soundOn = true,
    this.farCm = djiObstacleDefaultFarCm,
    this.nearCm = djiObstacleDefaultNearCm,
    this.sideTest = false,
    this.sideOff = false,
    this.hapticOn = false,
    this.numbersOn = false,
    this.tv = false,
  });

  /// The test switch, while the ring's data is likely: off by default
  final bool alertOn;

  /// This device's tick: on by default on a phone and a headset, off on a TV
  final bool soundOn;
  final int farCm;
  final int nearCm;

  /// "Show the side, not confirmed yet": off by default
  final bool sideTest;

  /// "Show the side" turned off once the side is proven
  final bool sideOff;

  /// "Vibrate with the tick", on a phone: off by default
  final bool hapticOn;

  /// "Show the distance by the glow": off by default
  final bool numbersOn;

  /// This device is a TV: its sound is kept apart, off by default
  final bool tv;

  double get farM => farCm / 100;
  double get nearM => nearCm / 100;

  /// Whether the ring is offered on this device: never while no field is named, once the pilot turned it on while it
  /// is a test, always once proven
  bool offered(DjiObstacleOffer offer) => switch (offer) {
    DjiObstacleOffer.none => false,
    DjiObstacleOffer.test => alertOn,
    DjiObstacleOffer.proven => true,
  };

  /// Whether the ring shows the obstacle's side: behind its own test switch while likely, by default once proven
  bool directional(DjiObstacleSideOffer offer) => switch (offer) {
    DjiObstacleSideOffer.none => false,
    DjiObstacleSideOffer.test => sideTest,
    DjiObstacleSideOffer.proven => !sideOff,
  };

  DjiObstacleSettings copyWith({
    bool? alertOn,
    bool? soundOn,
    int? farCm,
    int? nearCm,
    bool? sideTest,
    bool? sideOff,
    bool? hapticOn,
    bool? numbersOn,
  }) => DjiObstacleSettings(
    alertOn: alertOn ?? this.alertOn,
    soundOn: soundOn ?? this.soundOn,
    farCm: farCm ?? this.farCm,
    nearCm: nearCm ?? this.nearCm,
    sideTest: sideTest ?? this.sideTest,
    sideOff: sideOff ?? this.sideOff,
    hapticOn: hapticOn ?? this.hapticOn,
    numbersOn: numbersOn ?? this.numbersOn,
    tv: tv,
  );
}

class DjiObstacleSettingsNotifier extends Notifier<DjiObstacleSettings> {
  @override
  DjiObstacleSettings build() {
    final memory = ref.watch(djiLiveMemoryProvider);
    final tv = ref.watch(tvDeviceProvider).isTelevision;
    final (far, near) = djiObstacleDistancesCm(
      memory.readInt(StoreKey.djiObstacleFarCm) ?? djiObstacleDefaultFarCm,
      memory.readInt(StoreKey.djiObstacleNearCm) ?? djiObstacleDefaultNearCm,
    );
    return DjiObstacleSettings(
      alertOn: memory.read(StoreKey.djiObstacleAlertOn),
      soundOn: tv ? memory.read(StoreKey.djiObstacleTvSoundOn) : !memory.read(StoreKey.djiObstacleSoundOff),
      farCm: far,
      nearCm: near,
      sideTest: memory.read(StoreKey.djiObstacleSideTest),
      sideOff: memory.read(StoreKey.djiObstacleSideOff),
      hapticOn: memory.read(StoreKey.djiObstacleHapticOn),
      numbersOn: memory.read(StoreKey.djiObstacleNumbersOn),
      tv: tv,
    );
  }

  DjiLiveMemory get _memory => ref.read(djiLiveMemoryProvider);

  Future<void> setAlert(bool on) async {
    state = state.copyWith(alertOn: on);
    await _memory.write(StoreKey.djiObstacleAlertOn, on);
    await sync();
  }

  Future<void> setSound(bool on) async {
    state = state.copyWith(soundOn: on);
    if (state.tv) {
      await _memory.write(StoreKey.djiObstacleTvSoundOn, on);
    } else {
      await _memory.write(StoreKey.djiObstacleSoundOff, !on);
    }
    await sync();
  }

  /// "Glow from": "Strong glow from" follows it down when it would come within 0.5 m
  Future<void> setFar(int cm) async {
    final (far, near) = djiObstacleDistancesCm(cm, state.nearCm);
    state = state.copyWith(farCm: far, nearCm: near);
    await _memory.writeInt(StoreKey.djiObstacleFarCm, far);
    await _memory.writeInt(StoreKey.djiObstacleNearCm, near);
    await sync();
  }

  /// "Strong glow from", within its stepper and at least 0.5 m under "Glow from"
  Future<void> setNear(int cm) async {
    final (far, near) = djiObstacleDistancesCm(state.farCm, cm);
    state = state.copyWith(farCm: far, nearCm: near);
    await _memory.writeInt(StoreKey.djiObstacleNearCm, near);
    await sync();
  }

  /// "Show the side, not confirmed yet", while the side is likely
  Future<void> setSideTest(bool on) async {
    state = state.copyWith(sideTest: on);
    await _memory.write(StoreKey.djiObstacleSideTest, on);
    await sync();
  }

  /// "Show the side", once the side is proven
  Future<void> setSideShown(bool on) async {
    state = state.copyWith(sideOff: !on);
    await _memory.write(StoreKey.djiObstacleSideOff, !on);
    await sync();
  }

  Future<void> setHaptic(bool on) async {
    state = state.copyWith(hapticOn: on);
    await _memory.write(StoreKey.djiObstacleHapticOn, on);
    await sync();
  }

  Future<void> setNumbers(bool on) async {
    state = state.copyWith(numbersOn: on);
    await _memory.write(StoreKey.djiObstacleNumbersOn, on);
    await sync();
  }

  /// Tells the native side how this device draws and sounds the ring. An error (no bridge, as in a widget test) is
  /// only logged.
  Future<void> sync() async {
    final settings = state;
    try {
      await ref
          .read(djiLinkApiProvider)
          .setObstacleRing(
            DjiObstacleRingSettings(
              offered: settings.offered(djiObstacleOffer()),
              directional: settings.directional(djiObstacleSideOffer()),
              farM: settings.farM,
              nearM: settings.nearM,
              sound: settings.soundOn,
              haptic: settings.hapticOn && !settings.tv,
              numbers: settings.numbersOn,
            ),
          );
    } catch (error) {
      _log.fine('The obstacle ring settings did not reach the native side: $error');
    }
  }

  /// Three ticks, to check the volume before take off
  Future<void> playTest() async {
    try {
      await ref.read(djiLinkApiProvider).playObstacleTest();
    } catch (error) {
      _log.fine('The obstacle sound did not play: $error');
    }
  }

  /// Eight seconds of a made up ring on this device; false when refused (the motors run) or no bridge answers
  Future<bool> showSample() async {
    try {
      return await ref.read(djiLinkApiProvider).showObstacleSample();
    } catch (error) {
      _log.fine('No sample of the obstacle ring: $error');
      return false;
    }
  }

  /// The media volume, which the sound follows, is at zero; false when the native side cannot say
  Future<bool> mediaVolumeOff() async {
    try {
      return await ref.read(djiLinkApiProvider).mediaVolumeOff();
    } catch (error) {
      _log.fine('No answer for the media volume: $error');
      return false;
    }
  }

  /// This device can vibrate; false when the native side cannot say
  Future<bool> hasVibrator() async {
    try {
      return await ref.read(djiLinkApiProvider).hasVibrator();
    } catch (error) {
      _log.fine('No answer for the vibrator: $error');
      return false;
    }
  }
}

final djiObstacleSettingsProvider = NotifierProvider<DjiObstacleSettingsNotifier, DjiObstacleSettings>(
  DjiObstacleSettingsNotifier.new,
  dependencies: [djiLiveMemoryProvider, djiLinkApiProvider],
);

/// A headset's choice in Options (review-relay-2026-10-25 M4): the lowest delay behind the phone, with less smoothing
/// of the Wi-Fi. Off by default; a TV keeps its own buffer whatever it says.
class DjiLowestDelayNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(djiLiveMemoryProvider).read(StoreKey.djiHeadsetLowestDelay);

  Future<void> set(bool on) async {
    state = on;
    await ref.read(djiLiveMemoryProvider).write(StoreKey.djiHeadsetLowestDelay, on);
    await sync();
  }

  /// Tells the native side. An error (no bridge, as in a widget test) is only logged.
  Future<void> sync() async {
    try {
      await ref.read(djiLinkApiProvider).setLowestDelay(state);
    } catch (error) {
      _log.fine('The lowest delay did not reach the native side: $error');
    }
  }
}

final djiLowestDelayProvider = NotifierProvider<DjiLowestDelayNotifier, bool>(
  DjiLowestDelayNotifier.new,
  dependencies: [djiLiveMemoryProvider, djiLinkApiProvider],
);
