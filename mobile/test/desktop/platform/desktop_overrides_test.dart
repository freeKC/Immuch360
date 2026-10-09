import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/desktop_overrides.dart';
import 'package:immich_mobile/services/widget.service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // home_widget has no implementation on a computer: each of its calls ends in a MissingPluginException, and the sign
  // in writes the credentials of the home screen widget (AuthNotifier.saveAuthInfo), so no sign in could succeed
  group('home screen widget on a computer', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer(overrides: desktopOverrides()));

    tearDown(() => container.dispose());

    test('writing the credentials at sign in completes without a plugin', () async {
      await expectLater(
        container.read(widgetServiceProvider).writeCredentials('https://photos.example.org', 'TEST-TOKEN', null),
        completes,
      );
    });

    test('clearing them at sign out completes without a plugin', () async {
      await expectLater(container.read(widgetServiceProvider).clearCredentials(), completes);
    });
  });
}
