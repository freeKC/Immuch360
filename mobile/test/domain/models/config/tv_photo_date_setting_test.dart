import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';

// "Show photo date and time" of a TV: the date and time of a photo at the bottom left of the viewer, with its controls
void main() {
  test('is on by default', () {
    expect(const AppConfig().viewer.tvShowDateTime, isTrue);
    expect(defaultConfig.read(SettingsKey.viewerTvShowDateTime), isTrue);
  });

  test('a stored off wins over the default, and on comes back', () {
    final config = AppConfig.fromEntries({SettingsKey.viewerTvShowDateTime: false});

    expect(config.viewer.tvShowDateTime, isFalse);
    expect(config.read(SettingsKey.viewerTvShowDateTime), isFalse);
    expect(config.write(SettingsKey.viewerTvShowDateTime, true).viewer.tvShowDateTime, isTrue);
  });

  test('changes no other setting of the viewer', () {
    final config = const AppConfig().write(SettingsKey.viewerTvShowDateTime, false);

    expect(config.viewer.copyWith(tvShowDateTime: true), const AppConfig().viewer);
  });
}
