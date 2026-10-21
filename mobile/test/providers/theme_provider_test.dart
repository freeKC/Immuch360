// The theme mode of the app: Automatic is dark on a TV, whose system theme is often light; Light and Dark stay as
// chosen, and nothing changes off a TV.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/theme_config.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';

void main() {
  group('resolveThemeMode', () {
    test('Automatic is dark on a TV', () {
      expect(resolveThemeMode(ThemeMode.system, television: true), ThemeMode.dark);
    });

    test('Automatic follows the system off a TV', () {
      expect(resolveThemeMode(ThemeMode.system, television: false), ThemeMode.system);
    });

    test('Light and Dark stay as chosen, on a TV or not', () {
      for (final television in [true, false]) {
        expect(resolveThemeMode(ThemeMode.light, television: television), ThemeMode.light, reason: '$television');
        expect(resolveThemeMode(ThemeMode.dark, television: television), ThemeMode.dark, reason: '$television');
      }
    });
  });

  group('appThemeModeProvider', () {
    ThemeMode read({required ThemeMode mode, required bool isTelevision, TvLayoutMode layout = TvLayoutMode.auto}) {
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(
            AppConfig(
              theme: ThemeConfig(mode: mode),
              tvLayout: layout,
            ),
          ),
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: isTelevision, isLowRamDevice: false)),
        ],
      );
      addTearDown(container.dispose);
      return container.read(appThemeModeProvider);
    }

    test('the default setting gives a dark app on a TV and the system theme elsewhere', () {
      expect(const AppConfig().theme.mode, ThemeMode.system);
      expect(read(mode: ThemeMode.system, isTelevision: true), ThemeMode.dark);
      expect(read(mode: ThemeMode.system, isTelevision: false), ThemeMode.system);
    });

    test('a TV user who chose Light keeps it', () {
      expect(read(mode: ThemeMode.light, isTelevision: true), ThemeMode.light);
    });

    test('follows the device, not the remote control layout', () {
      expect(read(mode: ThemeMode.system, isTelevision: false, layout: TvLayoutMode.on), ThemeMode.system);
      expect(read(mode: ThemeMode.system, isTelevision: true, layout: TvLayoutMode.off), ThemeMode.dark);
    });
  });
}
