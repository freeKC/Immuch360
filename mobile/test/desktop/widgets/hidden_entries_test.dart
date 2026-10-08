// What a computer leaves out (design 7.1 and 7.2): the haptics setting, Cast in the viewer's menu, "Delete from
// device", the map of the location editor, whose coordinates stay, the Places card of the Library, the map of the
// details, and the mobile data and charging options of the backup, replaced by a line saying that the backup runs
// while the app is open. The phones keep every one of them. The settings list and the OAuth line are tested with their
// pages (settings_page_test.dart, login_form_tv_test.dart).

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';
import 'package:immich_mobile/widgets/asset_viewer/detail_panel/exif_map.dart';
import 'package:immich_mobile/widgets/common/location_picker.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:immich_mobile/widgets/settings/backup_settings/backup_settings.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';

const _desktops = [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux];

ActionButtonContext _viewerContext(BaseAsset asset) => ActionButtonContext(
  asset: asset,
  isOwner: true,
  isArchived: false,
  isStacked: false,
  isInLockedView: false,
  currentAlbum: null,
  advancedTroubleshooting: false,
  source: ActionSource.viewer,
);

final _remote = RemoteAsset(
  id: 'remote',
  name: 'remote.jpg',
  ownerId: 'owner',
  checksum: 'checksum',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  isEdited: false,
);

final _merged = LocalAsset(
  id: 'local',
  remoteId: 'remote',
  name: 'local.jpg',
  checksum: 'checksum',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Cast and "Delete from device" stay on the phones only', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final phone = !_desktops.contains(platform);
      expect(ActionButtonType.cast.shouldShow(_viewerContext(_remote)), phone, reason: platform.name);
      expect(ActionButtonType.deleteLocal.shouldShow(_viewerContext(_merged)), phone, reason: platform.name);
    }
  });

  group('the preferences', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    testWidgets('a computer has no haptics setting', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpTestWidget(context, const PreferenceSetting());
      expect(find.text('Haptic Feedback'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps it', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpTestWidget(context, const PreferenceSetting());
      expect(find.text('Haptic Feedback'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the location editor', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    Future<void> openEditor(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLocationPicker(context: context),
            child: const Text('edit'),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      expect(find.text('Location'), findsOneWidget);
    }

    testWidgets('a computer has no map to choose on, the coordinates stay', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await openEditor(tester);
      expect(find.text('Choose on map'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps its map', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await openEditor(tester);
      expect(find.text('Choose on map'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the Library', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
      when(context.service.user.tryGetMyUser).thenReturn(null);
    });

    tearDown(() async => context.dispose());

    /// The Library with a server, under a router whose other routes render a stub page
    Future<void> pumpLibrary(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(
            path: '/',
            initial: true,
            page: PageInfo(LibraryRoute.name, builder: (_) => const LibraryPage()),
          ),
          AutoRoute(
            path: '/local-albums',
            page: PageInfo(LocalAlbumsRoute.name, builder: (_) => const Text('device albums')),
          ),
        ],
      );
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
              ...context.overrides,
              tvModeProvider.overrideWithValue(false),
              localSessionProvider.overrideWith(_ServerSession.new),
              localAlbumProvider.overrideWith((ref) => Stream.value(const [])),
              localeProvider.overrideWithValue(const Locale('en')),
              allMemoriesProvider.overrideWith((ref, _) async => const <Memory>[]),
            ],
            child: Builder(
              builder: (context) => MaterialApp.router(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                routerConfig: router.config(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The people of the test store load with an error, shown inside their card: not what these tests look at
      tester.takeException();
    }

    testWidgets('a computer has no Places card, and its albums are on this computer', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpLibrary(tester);
      expect(find.text('People'), findsOneWidget);
      expect(find.text('Places'), findsNothing);
      expect(find.text('On this computer'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    // The phones keep both: library_page_test.dart (On this device) and library_page_tv_test.dart (Places), whose
    // map cannot be built in a test without its platform channel
  });

  group('the details of an asset', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    testWidgets('a computer shows no map, even with coordinates', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpTestWidget(context, const ExifMap(exifInfo: ExifInfo(latitude: 48.85, longitude: 2.35)));
      expect(find.byType(MapThumbnail), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the backup settings', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    Future<void> pumpBackupSettings(WidgetTester tester) => tester.pumpTestWidget(
      context,
      const BackupSettings(),
      overrides: [appConfigProvider.overrideWithValue(const AppConfig())],
    );

    testWidgets('a computer says that the backup runs while the app is open, without the phone options', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpBackupSettings(tester);
      expect(find.textContaining('Backup runs while Immuch360 Desktop is open'), findsOneWidget);
      expect(find.text('Network Requirements'), findsNothing);
      expect(find.text('Background Options'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps its mobile data options', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpBackupSettings(tester);
      expect(find.textContaining('Backup runs while Immuch360 Desktop is open'), findsNothing);
      expect(find.text('Network Requirements'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

/// A session with a server, whatever the Store says
class _ServerSession extends LocalSessionNotifier {
  @override
  bool build() => false;
}
