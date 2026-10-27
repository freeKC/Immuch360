// What a computer leaves out (design 7.1 and 7.2): the haptics setting, Cast in the viewer's menu, "Delete from
// device", the map of the location editor, whose coordinates stay, the Places card of the Library, the map of the
// details, and the mobile data and charging options of the backup, replaced by a line saying that the backup runs
// while the app is open. The phones keep every one of them. The settings list and the OAuth line are tested with their
// pages (settings_page_test.dart, login_form_tv_test.dart). The other way round, "Make 3D (AI)" and the button of its
// conversions are on the computers only, and never in the locked folder nor in the trash.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_bar_button.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
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
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/location_picker.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:immich_mobile/widgets/settings/backup_settings/backup_settings.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';

const _desktops = [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux];

ActionButtonContext _viewerContext(
  BaseAsset asset, {
  bool locked = false,
  TimelineOrigin origin = TimelineOrigin.main,
}) => ActionButtonContext(
  asset: asset,
  isOwner: true,
  isArchived: false,
  isStacked: false,
  isInLockedView: locked,
  currentAlbum: null,
  advancedTroubleshooting: false,
  source: ActionSource.viewer,
  timelineOrigin: origin,
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

  test('"Make 3D (AI)" is on the computers only: the menu of the viewer, its button, the selection sheets', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final computer = _desktops.contains(platform);
      expect(ActionButtonType.makeImmersive.shouldShow(_viewerContext(_remote)), computer, reason: platform.name);
      expect(
        ActionButtonType.makeImmersive.buildButton(_viewerContext(_remote)),
        computer ? isA<DesktopMakeImmersiveButton>() : isNot(isA<DesktopMakeImmersiveButton>()),
        reason: platform.name,
      );
      final actions = withDesktopSelectionActions(const [SizedBox.shrink()]);
      expect(actions.whereType<DesktopMakeImmersiveButton>(), hasLength(computer ? 1 : 0), reason: platform.name);
      expect(actions, hasLength(computer ? 2 : 1), reason: platform.name);
    }
  });

  test('"Make 3D (AI)" is never offered in the locked folder, where nothing takes a photo out, nor in the trash', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final locked = _viewerContext(_remote, locked: true, origin: TimelineOrigin.lockedFolder);
    expect(ActionButtonType.download.shouldShow(locked), isFalse);
    expect(ActionButtonType.shareLink.shouldShow(locked), isFalse);
    expect(ActionButtonType.makeImmersive.shouldShow(locked), isFalse);
    expect(ActionButtonType.makeImmersive.shouldShow(_viewerContext(_remote, locked: true)), isFalse);
    expect(ActionButtonType.makeImmersive.shouldShow(_viewerContext(_remote, origin: TimelineOrigin.trash)), isFalse);
    expect(ActionButtonType.makeImmersive.shouldShow(_viewerContext(_merged)), isTrue);
    final video = RemoteAsset(
      id: 'clip',
      name: 'clip.mp4',
      ownerId: 'owner',
      checksum: 'clip',
      type: AssetType.video,
      createdAt: DateTime(2025),
      updatedAt: DateTime(2025),
      isEdited: false,
    );
    expect(ActionButtonType.makeImmersive.shouldShow(_viewerContext(video)), isFalse);
  });

  group('the app bar', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    /// The app bar of a session without a server (no backup button), the AI features on
    Future<void> pumpAppBar(WidgetTester tester, TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
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
              localSessionProvider.overrideWith(_LocalSession.new),
              localeProvider.overrideWithValue(const Locale('en')),
              aiFeaturesEnabledProvider.overrideWith((ref) => true),
            ],
            child: Builder(
              builder: (context) => MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                home: const Scaffold(body: CustomScrollView(slivers: [ImmichSliverAppBar()])),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('of a computer has the button of the 3D conversions', (tester) async {
      await pumpAppBar(tester, TargetPlatform.windows);
      expect(find.byType(DesktopConversionsBarButton), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('of a phone does not', (tester) async {
      await pumpAppBar(tester, TargetPlatform.android);
      expect(find.byType(DesktopConversionsBarButton), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
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

/// A session without a server: no backup button in the app bar
class _LocalSession extends LocalSessionNotifier {
  @override
  bool build() => true;
}
