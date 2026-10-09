// The two references of the shared code to the desktop pages, the folders route and the "This computer" settings
// section, exist on the computers only: on a phone build the condition is a constant, so the folders page, the folder
// library and the computer settings behind them stay out of the app (design 1.1).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/settings/computer_settings.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/local_auth.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';

class _LocalAuthService extends Mock implements LocalAuthService {}

const _desktops = {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux};

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the folders page is a route on the computers only', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final router = AppRouter(MockApiService(), MockAuthService(), MockSecureStorageService(), _LocalAuthService());
      expect(
        router.routes.any((route) => route.name == FoldersRoute.name),
        _desktops.contains(platform),
        reason: platform.name,
      );
      // The other routes stay
      expect(router.routes.any((route) => route.name == SettingsRoute.name), isTrue, reason: platform.name);
    }
  });

  test('the "This computer" section builds the computer settings on the computers only', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final widget = SettingSection.thisComputer.widget;
      expect(widget, _desktops.contains(platform) ? isA<ComputerSettings>() : isA<SizedBox>(), reason: platform.name);
    }
  });
}
