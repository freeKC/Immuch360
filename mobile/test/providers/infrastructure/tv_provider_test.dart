// The remote control layout: on by itself on Android TV and Google TV, forced on or off by the setting, never on iOS.
// On a TV the app is a viewer, as in the read only mode, which a timeline may also scope to itself.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

class _ReadOnly extends ReadOnlyModeNotifier {
  _ReadOnly(this.value);

  final bool value;

  @override
  bool build() => value;
}

class _MockTvApi extends Mock implements TvApi {}

void main() {
  ProviderContainer container({TvLayoutMode? layout, bool isTelevision = false, bool readOnly = false}) {
    final created = ProviderContainer(
      overrides: [
        if (layout != null) appConfigProvider.overrideWithValue(AppConfig(tvLayout: layout)),
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: isTelevision, isLowRamDevice: false)),
        readonlyModeProvider.overrideWith(() => _ReadOnly(readOnly)),
      ],
    );
    addTearDown(created.dispose);
    return created;
  }

  group('tvModeProvider', () {
    test('Automatic follows the device', () {
      expect(container(layout: TvLayoutMode.auto, isTelevision: true).read(tvModeProvider), isTrue);
      expect(container(layout: TvLayoutMode.auto).read(tvModeProvider), isFalse);
    });

    test('On and Off whatever the device', () {
      expect(container(layout: TvLayoutMode.on).read(tvModeProvider), isTrue);
      expect(container(layout: TvLayoutMode.off, isTelevision: true).read(tvModeProvider), isFalse);
    });

    test('Automatic by default, and when the settings are not loaded', () {
      expect(const AppConfig().tvLayout, TvLayoutMode.auto);
      expect(container(isTelevision: true).read(tvModeProvider), isTrue);
      expect(container().read(tvModeProvider), isFalse);
    });

    test('never on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(container(layout: TvLayoutMode.on, isTelevision: true).read(tvModeProvider), isFalse);
    });

    test('not a TV unless main() says so', () {
      final plain = ProviderContainer();
      addTearDown(plain.dispose);

      expect(plain.read(tvDeviceProvider).isTelevision, isFalse);
      expect(plain.read(tvDeviceProvider).isLowRamDevice, isFalse);
    });
  });

  group('viewOnlyProvider', () {
    test('in the read only mode, on a TV, or both', () {
      expect(container(layout: TvLayoutMode.off).read(viewOnlyProvider), isFalse);
      expect(container(layout: TvLayoutMode.off, readOnly: true).read(viewOnlyProvider), isTrue);
      expect(container(layout: TvLayoutMode.on).read(viewOnlyProvider), isTrue);
      expect(container(layout: TvLayoutMode.on, readOnly: true).read(viewOnlyProvider), isTrue);
    });

    test('follows the read only mode scoped to a timeline, as Timeline(readOnly: true) does', () {
      final root = container(layout: TvLayoutMode.off);
      final timeline = ProviderContainer(
        parent: root,
        overrides: [readonlyModeProvider.overrideWith(() => _ReadOnly(true))],
      );
      addTearDown(timeline.dispose);

      expect(root.read(viewOnlyProvider), isFalse);
      expect(timeline.read(viewOnlyProvider), isTrue);
    });
  });

  group('readTvDeviceInfo', () {
    test('is not a TV off Android, without asking the platform', () async {
      final api = _MockTvApi();

      final info = await readTvDeviceInfo(api: api);

      expect(info.isTelevision, isFalse);
      verifyNever(() => api.deviceInfo());
    });
  });
}
