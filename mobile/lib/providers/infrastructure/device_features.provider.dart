// What this device can do, one answer per capability, so that the pages hide an entry by asking here rather than
// testing the platform themselves. The phones answer as before; the computers (Immuch360 Desktop) leave out what
// needs a phone sensor, a system service of Android or iOS, or a plugin with no desktop implementation.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// "Share this phone" or "Share this computer": the wording of the share of the device on the network
enum ShareThisDevice { phone, computer }

class DeviceFeatures {
  const DeviceFeatures({
    required this.gyroscope,
    required this.systemBackgroundBackup,
    required this.homeWidgets,
    required this.shareTarget,
    required this.maps,
    required this.cast,
    required this.biometrics,
    required this.oauth,
    required this.galleryPermission,
    required this.batteryOptimisation,
    required this.freeUpSpace,
    required this.notifications,
    required this.haptics,
    required this.deleteFromDevice,
    required this.videoPlayback,
    required this.shareThisDevice,
  });

  /// The phones and their remote control layout
  static DeviceFeatures phone({required bool tvMode}) => DeviceFeatures(
    gyroscope: !tvMode,
    systemBackgroundBackup: true,
    homeWidgets: true,
    shareTarget: true,
    maps: !tvMode,
    cast: true,
    biometrics: true,
    oauth: true,
    galleryPermission: true,
    batteryOptimisation: true,
    freeUpSpace: true,
    notifications: true,
    haptics: true,
    deleteFromDevice: true,
    videoPlayback: true,
    shareThisDevice: ShareThisDevice.phone,
  );

  /// Immuch360 Desktop on Windows, macOS and Linux
  static DeviceFeatures desktop({required bool isLinux}) => DeviceFeatures(
    gyroscope: false,
    systemBackgroundBackup: false,
    homeWidgets: false,
    shareTarget: false,
    // maplibre_gl has no desktop implementation
    maps: false,
    // Not checked on a computer yet
    cast: false,
    // local_auth has Windows Hello and Touch ID, nothing on Linux
    biometrics: !isLinux,
    // flutter_web_auth_2 needs a localhost redirect on Windows and Linux, which the server must accept: not checked
    oauth: false,
    galleryPermission: false,
    batteryOptimisation: false,
    freeUpSpace: false,
    // flutter_local_notifications 17 has no Windows implementation
    notifications: false,
    haptics: false,
    // Until the files can go to the system's trash: never a permanent delete of the user's files
    deleteFromDevice: false,
    // Until the desktop player exists, a placeholder stands for the video
    videoPlayback: false,
    shareThisDevice: ShareThisDevice.computer,
  );

  /// The gyroscope mode of the 360° photo viewer
  final bool gyroscope;

  /// Backup started by the system with the app closed (WorkManager, BGTaskScheduler)
  final bool systemBackgroundBackup;

  /// Home screen widgets
  final bool homeWidgets;

  /// Files shared to the app from other apps
  final bool shareTarget;

  /// The map of the places and the map of the details of an asset
  final bool maps;

  /// Google Cast
  final bool cast;

  /// Unlocking the locked folder with the fingerprint, the face or Windows Hello
  final bool biometrics;

  /// Signing in through the identity provider of the server
  final bool oauth;

  /// The gallery permission banner and tiles of the phones
  final bool galleryPermission;

  /// The battery optimisation and media management tiles
  final bool batteryOptimisation;

  /// "Free up space" on the device
  final bool freeUpSpace;

  /// Notifications of the system and their permission
  final bool notifications;

  /// The haptic feedback setting
  final bool haptics;

  /// "Delete from device"
  final bool deleteFromDevice;

  /// Playing videos in the viewers
  final bool videoPlayback;

  final ShareThisDevice shareThisDevice;
}

/// Read once by each place that hides an entry. Follows the remote control layout of a TV (tvModeProvider), hence
/// auto dispose like it.
final deviceFeaturesProvider = Provider.autoDispose<DeviceFeatures>((ref) {
  if (CurrentPlatform.isDesktop) {
    return DeviceFeatures.desktop(isLinux: CurrentPlatform.isLinux);
  }
  return DeviceFeatures.phone(tvMode: ref.watch(tvModeProvider));
});
