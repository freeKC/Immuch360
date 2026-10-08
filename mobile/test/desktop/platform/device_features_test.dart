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
    expect([phone.gyroscope, phone.maps, phone.oauth, phone.haptics], everyElement(isTrue));

    final tv = read(tvMode: true);
    expect(tv.gyroscope, isFalse);
    expect(tv.maps, isFalse);
    expect(tv.oauth, isTrue);
    expect(tv.haptics, isTrue);
  });

  test('a computer leaves out what needs a phone', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      final computer = read(tvMode: false);
      expect(
        [computer.gyroscope, computer.maps, computer.oauth, computer.haptics],
        everyElement(isFalse),
        reason: platform.name,
      );
      // The remote control layout changes nothing there
      expect(read(tvMode: true).maps, isFalse, reason: platform.name);
    }
  });
}
