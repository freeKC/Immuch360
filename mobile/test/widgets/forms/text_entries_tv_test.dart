// The text fields a TV reaches beyond the login form go through the native text dialog too: the passwords of the
// change asked at the first sign in, the custom headers of a proxy, and the Wi-Fi name and local address of the
// networking settings. Out of TV mode they are untouched.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/headers_settings.page.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/forms/change_password_form.dart';
import 'package:immich_mobile/widgets/settings/networking_settings/local_network_preference.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';

class _MockTvApi extends Mock implements TvApi {}

/// Records the password changes and the local network settings, without a server
class _Auth extends AuthNotifier {
  _Auth(Ref ref)
    : super(
        MockAuthService(),
        MockApiService(),
        MockUserService(),
        MockSecureStorageService(),
        MockWidgetService(),
        ref,
      );

  final List<(String, String)> changes = [];
  final List<String> wifiNames = [];
  final List<String> localEndpoints = [];

  @override
  Future<bool> changePassword({required String currentPassword, required String newPassword}) async {
    changes.add((currentPassword, newPassword));
    // Refused: the form stays, nothing signs out
    return false;
  }

  @override
  String? getSavedWifiName() => null;

  @override
  String? getSavedLocalEndpoint() => null;

  @override
  Future<void> saveWifiName(String wifiName) async => wifiNames.add(wifiName);

  @override
  Future<void> saveLocalEndpoint(String url) async => localEndpoints.add(url);
}

void main() {
  late _MockTvApi tvApi;
  late List<TvTextRequest> requests;

  setUpAll(() {
    registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
  });

  setUp(() {
    tvApi = _MockTvApi();
    requests = [];
  });

  /// The dialog of the TV answers [answers] one after the other
  void answer(List<String> answers) {
    final queue = [...answers];
    when(() => tvApi.editText(any())).thenAnswer((invocation) async {
      requests.add(invocation.positionalArguments.single as TvTextRequest);
      return queue.removeAt(0);
    });
  }

  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {bool tvMode = true}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            authProvider.overrideWith(_Auth.new),
            tvModeProvider.overrideWithValue(tvMode),
            tvApiProvider.overrideWithValue(tvApi),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byWidget(child)));
  }

  Future<void> ok(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
  }

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    final targets = finder.evaluate().toSet();
    var found = targets.contains(focused);
    focused.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found;
  }

  testWidgets('the change of password: each password in the dialog, the last one sends the change', (tester) async {
    answer(['old secret', 'new secret', 'new secret']);
    final container = await pump(tester, const ChangePasswordForm());
    final entries = find.byType(TvTextEntry);
    expect(entries, findsNWidgets(3));
    expect(focusedIn(entries.at(0)), isTrue, reason: 'the current password first');

    await ok(tester);
    expect(focusedIn(entries.at(1)), isTrue, reason: 'then the new one');
    await ok(tester);
    expect(focusedIn(entries.at(2)), isTrue, reason: 'then its confirmation');
    await ok(tester);

    expect(requests.map((request) => request.kind), everyElement(TvTextKind.password));
    expect(requests.map((request) => request.text), everyElement(''), reason: 'a password is never shown');
    expect((container.read(authProvider.notifier) as _Auth).changes, [('old secret', 'new secret')]);
    // The toast of the refused change goes away
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a phone types the passwords in the fields, as before', (tester) async {
    await pump(tester, const ChangePasswordForm(), tvMode: false);

    expect(find.byType(TextFormField), findsNWidgets(3));
    await tester.enterText(find.byType(TextFormField).first, 'typed');
    expect(find.text('typed'), findsOneWidget);
    verifyNever(() => tvApi.editText(any()));
  });

  testWidgets('a custom header: its name and its value in the dialog', (tester) async {
    answer(['X-Proxy-Key', 'abc123']);
    final header = SettingsHeader();
    await pump(tester, HeaderKeyValueSettings(header: header, onRemove: () {}));
    final entries = find.byType(TvTextEntry);

    await tester.tap(entries.at(0));
    await tester.pumpAndSettle();
    expect(requests.single.title, 'Header name');
    expect(header.key, 'X-Proxy-Key');

    await tester.tap(entries.at(1));
    await tester.pumpAndSettle();
    expect(header.value, 'abc123');
    expect(find.text('X-Proxy-Key'), findsOneWidget);
  });

  testWidgets('the Wi-Fi name of the local network: typed in the dialog, saved at once', (tester) async {
    answer(['Home WiFi']);
    final container = await pump(tester, const LocalNetworkPreference(enabled: true));

    await tester.tap(find.byIcon(Icons.edit_rounded).first);
    await tester.pumpAndSettle();
    expect(focusedIn(find.byType(TvTextEntry)), isTrue);
    await ok(tester);

    expect(requests.single.kind, TvTextKind.text);
    expect((container.read(authProvider.notifier) as _Auth).wifiNames, ['Home WiFi']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Home WiFi'), findsOneWidget);
  });

  testWidgets('the local address: an address in the dialog', (tester) async {
    answer(['http://192.168.1.20:2283']);
    final container = await pump(tester, const LocalNetworkPreference(enabled: true));

    await tester.tap(find.byIcon(Icons.edit_rounded).last);
    await tester.pumpAndSettle();
    await ok(tester);

    expect(requests.single.kind, TvTextKind.url);
    expect((container.read(authProvider.notifier) as _Auth).localEndpoints, ['http://192.168.1.20:2283']);
  });
}
