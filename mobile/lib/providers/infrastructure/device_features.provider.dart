// What this device can do, one answer per capability, for the widgets that hide an entry and can read a provider. The
// phones answer as before; the computers (Immuch360 Desktop) leave out what needs a phone sensor or a plugin with no
// desktop implementation.
//
// Only the capabilities a widget reads are here: an answer nobody reads would let its test pass while the entry still
// shows. The other entries a computer leaves out (design 7.2) test CurrentPlatform.isDesktop where they are built,
// some of them where no provider can be read: the settings sections (SettingSection.isOnThisDevice: free up space, the
// notifications), the actions of the viewer (ActionButtonType.shouldShow: Cast, "Delete from device"), the backup
// settings and the banner of the gallery permission. hidden_entries_test.dart and the tests of those pages check them
// on a computer.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

class DeviceFeatures {
  const DeviceFeatures({required this.gyroscope, required this.maps, required this.oauth, required this.haptics});

  /// The phones and their remote control layout
  static DeviceFeatures phone({required bool tvMode}) =>
      DeviceFeatures(gyroscope: !tvMode, maps: !tvMode, oauth: true, haptics: true);

  /// Immuch360 Desktop on Windows, macOS and Linux
  static const desktop = DeviceFeatures(
    gyroscope: false,
    // maplibre_gl has no desktop implementation
    maps: false,
    // flutter_web_auth_2 needs a localhost redirect on Windows and Linux, which the server must accept: not checked
    oauth: false,
    haptics: false,
  );

  /// The gyroscope mode of the 360° photo viewer
  final bool gyroscope;

  /// The map of the places and the map of the details of an asset
  final bool maps;

  /// Signing in through the identity provider of the server
  final bool oauth;

  /// The haptic feedback setting
  final bool haptics;
}

/// Read once by each place that hides an entry. Follows the remote control layout of a TV (tvModeProvider), hence
/// auto dispose like it.
final deviceFeaturesProvider = Provider.autoDispose<DeviceFeatures>((ref) {
  if (CurrentPlatform.isDesktop) {
    return DeviceFeatures.desktop;
  }
  return DeviceFeatures.phone(tvMode: ref.watch(tvModeProvider));
});
