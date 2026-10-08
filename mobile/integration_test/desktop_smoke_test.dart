// The first check of Immuch360 Desktop on a real computer, run in a slot the owner gave (it opens a window):
//   flutter test integration_test/desktop_smoke_test.dart -d windows
// It starts the app as lib/main_desktop.dart does, without the window setup, and waits for the first page: the login
// page, or the timeline when a server is already saved in this profile.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/desktop/platform/desktop_overrides.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/main.dart' as app;
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Immuch360 Desktop starts to its first page', (tester) async {
    expect(CurrentPlatform.isDesktop, isTrue, reason: 'run with -d windows, -d linux or -d macos');

    await EasyLocalization.ensureInitialized();
    final (dataController, apiService) = await Bootstrap.initDomain();
    await app.initApp();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...Store.overrideWith(dataController: dataController, apiService: apiService),
          ...desktopOverrides(),
        ],
        child: const app.MainWidget(),
      ),
    );

    final firstPage = find.byWidgetPredicate((widget) => widget is LoginForm || widget is TabShellPage);
    for (var i = 0; i < 300 && firstPage.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(firstPage, findsWidgets);
    debugPrint('First page: ${find.byType(LoginForm).evaluate().isNotEmpty ? 'login' : 'timeline'}');
  });
}
