import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/library/folders.page.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> pumpTranslated(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('settings sections', () {
    test('"This computer" on the computers only, free up space and notifications on the phones only', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final desktop = const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(platform);
        expect(SettingSection.thisComputer.isOnThisDevice, desktop, reason: platform.name);
        expect(SettingSection.freeUpSpace.isOnThisDevice, !desktop, reason: platform.name);
        expect(SettingSection.notifications.isOnThisDevice, !desktop, reason: platform.name);
        expect(SettingSection.backup.isOnThisDevice, isTrue);
      }
    });
  });

  testWidgets('the video placeholder says that playback comes later', (tester) async {
    await pumpTranslated(tester, const DesktopVideoPlaceholder());
    expect(find.text('Video playback comes to Immuch360 Desktop in a later version'), findsOneWidget);
  });

  testWidgets('the folders banner leads to the folders', (tester) async {
    await pumpTranslated(tester, const FoldersBanner());
    expect(find.text('Choose the folders of your photos and videos'), findsOneWidget);
    expect(find.byKey(const Key('desktop_folders_open')), findsOneWidget);
  });
}
