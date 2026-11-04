import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';

// The settings the app labels experimental are on by default, and each can still be turned off; Large splats is an
// exception, off until a measure in the headset (decision D7 of the splats), and Keep every gaussian another, off on
// the computers whose graphics chip shares their memory (lot SVC)
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

  group('3D by file name on the Meta Quest (experimental)', () {
    test('is on by default', () {
      expect(const AppConfig().viewer.flat3dByName, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerFlat3dByName), isTrue);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({SettingsKey.viewerFlat3dByName: false});

      expect(config.viewer.flat3dByName, isFalse);
      expect(config.write(SettingsKey.viewerFlat3dByName, true).viewer.flat3dByName, isTrue);
    });
  });

  group('Sharper flat screens on the Meta Quest (experimental)', () {
    test('is on by default', () {
      expect(const AppConfig().viewer.sharpFlatScreens, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerSharpFlatScreens), isTrue);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({SettingsKey.viewerSharpFlatScreens: false});

      expect(config.viewer.sharpFlatScreens, isFalse);
      expect(config.write(SettingsKey.viewerSharpFlatScreens, true).viewer.sharpFlatScreens, isTrue);
    });
  });

  group('Gaussian splats on the Meta Quest (experimental)', () {
    test('are on by default', () {
      expect(const AppConfig().viewer.gaussianSplats, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerGaussianSplats), isTrue);
    });

    test('Large splats is off by default: 50,000 gaussians until a measure in the headset says more (D7)', () {
      expect(const AppConfig().viewer.largeSplats, isFalse);
      expect(defaultConfig.read(SettingsKey.viewerLargeSplats), isFalse);
    });

    test('the dedicated graphics chip of a Windows computer is used by default (D2), a stored off wins', () {
      expect(const AppConfig().viewer.highPerformanceGpu, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerHighPerformanceGpu), isTrue);
      final config = AppConfig.fromEntries({SettingsKey.viewerHighPerformanceGpu: false});
      expect(config.viewer.highPerformanceGpu, isFalse);
      expect(config.write(SettingsKey.viewerHighPerformanceGpu, true).viewer.highPerformanceGpu, isTrue);
    });

    test('Keep every gaussian is off by default: a chip that shares the memory keeps 1,000,000 (lot SVC)', () {
      expect(const AppConfig().viewer.keepAllGaussians, isFalse);
      expect(defaultConfig.read(SettingsKey.viewerKeepAllGaussians), isFalse);
      final config = AppConfig.fromEntries({SettingsKey.viewerKeepAllGaussians: true});
      expect(config.viewer.keepAllGaussians, isTrue);
      expect(config.write(SettingsKey.viewerKeepAllGaussians, false).viewer.keepAllGaussians, isFalse);
    });

    test('the mark of the photos of saved splat scenes is on by default, and turns off (decision D1)', () {
      expect(const AppConfig().viewer.markSplatPhotos, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerMarkSplatPhotos), isTrue);
      final config = AppConfig.fromEntries({SettingsKey.viewerMarkSplatPhotos: false});
      expect(config.viewer.markSplatPhotos, isFalse);
      expect(config.write(SettingsKey.viewerMarkSplatPhotos, true).viewer.markSplatPhotos, isTrue);
    });

    test('a stored on wins over the default of Large splats', () {
      final config = AppConfig.fromEntries({SettingsKey.viewerLargeSplats: true});

      expect(config.viewer.largeSplats, isTrue);
      expect(config.write(SettingsKey.viewerLargeSplats, false).viewer.largeSplats, isFalse);
    });

    test('a stored off wins over the default', () {
      final config = AppConfig.fromEntries({
        SettingsKey.viewerGaussianSplats: false,
        SettingsKey.viewerLargeSplats: false,
      });

      expect(config.viewer.gaussianSplats, isFalse);
      expect(config.viewer.largeSplats, isFalse);
      expect(config.write(SettingsKey.viewerGaussianSplats, true).viewer.gaussianSplats, isTrue);
      expect(config.write(SettingsKey.viewerLargeSplats, true).viewer.largeSplats, isTrue);
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

  group('Remember where I stopped (the lab rule)', () {
    test('is on by default, for videos of 10 minutes or more', () {
      expect(const AppConfig().viewer.resumeVideos, isTrue);
      expect(defaultConfig.read(SettingsKey.viewerResumeVideos), isTrue);
      expect(defaultConfig.read(SettingsKey.viewerResumeMinMinutes), 10);
    });

    test('a stored off and a stored threshold win over the defaults', () {
      final config = AppConfig.fromEntries({
        SettingsKey.viewerResumeVideos: false,
        SettingsKey.viewerResumeMinMinutes: 0,
      });

      expect(config.viewer.resumeVideos, isFalse);
      expect(config.viewer.resumeMinMinutes, 0);
      expect(config.write(SettingsKey.viewerResumeVideos, true).viewer.resumeVideos, isTrue);
      expect(config.write(SettingsKey.viewerResumeMinMinutes, 25).viewer.resumeMinMinutes, 25);
    });
  });
}
