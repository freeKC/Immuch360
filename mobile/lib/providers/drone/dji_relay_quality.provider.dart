// "Relay quality" in Advanced (p2/relay-bandwidth-2026-10-25.md, 7.7 and 7.9): the drone's picture while a receiver's
// Wi-Fi keeps up and the phone's steady picture when it cannot (Automatic, on by default), the drone's picture always
// (Full stream, the off switch), or the phone's steady picture always (Steady stream). The choice is kept on the native
// side, which a running relay takes at once. What the phone sends a TV or a headset never reaches the remote.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiRelayQuality');

class DjiRelayQualityNotifier extends Notifier<DjiRelayQuality> {
  @override
  DjiRelayQuality build() => DjiRelayQuality.automatic;

  /// The choice the native side keeps; Automatic when it cannot say (no bridge, as in a widget test)
  Future<void> load() async {
    try {
      state = await ref.read(djiLinkApiProvider).relayQuality();
    } catch (error) {
      _log.fine('No answer for the relay quality: $error');
    }
  }

  Future<void> set(DjiRelayQuality quality) async {
    state = quality;
    try {
      await ref.read(djiLinkApiProvider).setRelayQuality(quality);
    } catch (error) {
      _log.fine('The relay quality did not reach the native side: $error');
    }
  }
}

final djiRelayQualityProvider = NotifierProvider<DjiRelayQualityNotifier, DjiRelayQuality>(
  DjiRelayQualityNotifier.new,
  dependencies: [djiLinkApiProvider],
);
