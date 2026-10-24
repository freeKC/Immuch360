// The values a pilot reads on the DJI live video, ten times a second (p2/design-final-2026-10-24.md, 3.4), and the
// pilot's choices about the obstacle alert. The frame is kept apart from the link's state, so that a number that moves
// with the flight redraws its own cell and nothing else: the page and the picture are never rebuilt by a value. The
// alert is information for the pilot: nothing here reaches the remote or the drone.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
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

/// What the pilot chose in Advanced: the alert while it is offered as a test (off by default), and its sound (on by
/// default)
class DjiObstacleSettings {
  const DjiObstacleSettings({this.alertOn = false, this.soundOn = true});

  final bool alertOn;
  final bool soundOn;

  /// Whether the alert is offered on this device: never while no field is named, once the pilot turned it on while it
  /// is a test, always once proven
  bool offered(DjiObstacleOffer offer) => switch (offer) {
    DjiObstacleOffer.none => false,
    DjiObstacleOffer.test => alertOn,
    DjiObstacleOffer.proven => true,
  };
}

class DjiObstacleSettingsNotifier extends Notifier<DjiObstacleSettings> {
  @override
  DjiObstacleSettings build() {
    final memory = ref.watch(djiLiveMemoryProvider);
    return DjiObstacleSettings(
      alertOn: memory.read(StoreKey.djiObstacleAlertOn),
      soundOn: !memory.read(StoreKey.djiObstacleSoundOff),
    );
  }

  Future<void> setAlert(bool on) async {
    state = DjiObstacleSettings(alertOn: on, soundOn: state.soundOn);
    await ref.read(djiLiveMemoryProvider).write(StoreKey.djiObstacleAlertOn, on);
    await sync();
  }

  Future<void> setSound(bool on) async {
    state = DjiObstacleSettings(alertOn: state.alertOn, soundOn: on);
    await ref.read(djiLiveMemoryProvider).write(StoreKey.djiObstacleSoundOff, !on);
    await sync();
  }

  /// Tells the native side whether the alert is offered and its sound on. An error (no bridge, as in a widget test)
  /// is only logged.
  Future<void> sync() async {
    try {
      await ref.read(djiLinkApiProvider).setObstacleAlert(state.offered(djiObstacleOffer()), state.soundOn);
    } catch (error) {
      _log.fine('The obstacle alert settings did not reach the native side: $error');
    }
  }

  /// Three beeps, to check the volume before take off
  Future<void> playTest() async {
    try {
      await ref.read(djiLinkApiProvider).playObstacleTest();
    } catch (error) {
      _log.fine('The obstacle sound did not play: $error');
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
}

final djiObstacleSettingsProvider = NotifierProvider<DjiObstacleSettingsNotifier, DjiObstacleSettings>(
  DjiObstacleSettingsNotifier.new,
  dependencies: [djiLiveMemoryProvider, djiLinkApiProvider],
);
