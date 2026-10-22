import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';

// The settings the app labels experimental are on by default, and each can still be turned off
void main() {
  group('DJI drones (experimental)', () {
    test('is on by default', () {
      expect(const AppConfig().djiImportEnabled, isTrue);
      expect(defaultConfig.read(SettingsKey.djiImportEnabled), isTrue);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({SettingsKey.djiImportEnabled: false});

      expect(config.djiImportEnabled, isFalse);
      expect(config.write(SettingsKey.djiImportEnabled, true).djiImportEnabled, isTrue);
    });
  });

  group('DJI link diagnostics (experimental)', () {
    test('is on by default', () {
      expect(const AppConfig().djiLinkEnabled, isTrue);
      expect(defaultConfig.read(SettingsKey.djiLinkEnabled), isTrue);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({SettingsKey.djiLinkEnabled: false});

      expect(config.djiLinkEnabled, isFalse);
      expect(config.write(SettingsKey.djiLinkEnabled, true).djiLinkEnabled, isTrue);
    });
  });

  group('Spatial 2.5D (experimental)', () {
    test('is on by default', () {
      expect(const AppConfig().viewer.spatial25d, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerSpatial25d), isTrue);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({SettingsKey.viewerSpatial25d: false});

      expect(config.viewer.spatial25d, isFalse);
      expect(config.write(SettingsKey.viewerSpatial25d, true).viewer.spatial25d, isTrue);
    });
  });
}
