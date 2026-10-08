import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/device_features.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  DeviceFeatures read({required bool tvMode}) {
    final container = ProviderContainer(overrides: [tvModeProvider.overrideWithValue(tvMode)]);
    addTearDown(container.dispose);
    return container.read(deviceFeaturesProvider);
  }

  test('a phone keeps everything, and its TV layout hides the gyroscope and the maps', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final phone = read(tvMode: false);
    expect([
      phone.gyroscope,
      phone.maps,
      phone.systemBackgroundBackup,
      phone.oauth,
      phone.freeUpSpace,
      phone.notifications,
      phone.deleteFromDevice,
      phone.videoPlayback,
      phone.biometrics,
    ], everyElement(isTrue));
    expect(phone.shareThisDevice, ShareThisDevice.phone);

    final tv = read(tvMode: true);
    expect(tv.gyroscope, isFalse);
    expect(tv.maps, isFalse);
    expect(tv.oauth, isTrue);
  });

  test('a computer leaves out what needs a phone', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      final computer = read(tvMode: false);
      expect(
        [
          computer.gyroscope,
          computer.maps,
          computer.systemBackgroundBackup,
          computer.homeWidgets,
          computer.shareTarget,
          computer.oauth,
          computer.freeUpSpace,
          computer.notifications,
          computer.deleteFromDevice,
          computer.videoPlayback,
          computer.galleryPermission,
        ],
        everyElement(isFalse),
        reason: platform.name,
      );
      expect(computer.shareThisDevice, ShareThisDevice.computer);
      // Windows Hello and Touch ID, nothing on Linux
      expect(computer.biometrics, platform != TargetPlatform.linux);
    }
  });
}
