// The way to "Folders on this computer" from the pages that list the albums of the device (design 1.6): Library > On
// this computer and the albums chosen for backup ask for a first folder while there is none, then offer one line to
// the folders page. The phones keep these pages as they were, "On this device" included.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/library/folders.page.dart';
import 'package:immich_mobile/desktop/library/folders_entry.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/services/local_album.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/backup/backup_album_selection.page.dart';
import 'package:immich_mobile/presentation/pages/local_album.page.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

class _AlbumService extends Mock implements LocalAlbumService {}

class _ForegroundUploads extends Mock implements ForegroundUploadService {}

class _BackgroundUploads extends Mock implements BackgroundUploadService {}

/// No album chosen for backup, none on the device
class _BackupAlbums extends BackupAlbumNotifier {
  _BackupAlbums() : super(_AlbumService());

  @override
  Future<void> getAll() async => state = const [];
}

class _Backup extends BackupNotifier {
  _Backup() : super(_ForegroundUploads(), _BackgroundUploads(), UploadSpeedManager());
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// Pumps [page] under a router whose folders route renders a stub page; [hasFolders] is the folder library
  Future<void> pumpPage(WidgetTester tester, Widget page, {bool? hasFolders = false}) async {
    tester.view
      ..physicalSize = const Size(1280, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('HomeRoute', builder: (_) => page),
        ),
        AutoRoute(
          path: '/folders',
          page: PageInfo(FoldersRoute.name, builder: (_) => const Text('folders page')),
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
            folderLibraryHasFoldersProvider.overrideWithValue(hasFolders),
            localAlbumProvider.overrideWith((ref) => Stream.value(const <LocalAlbum>[])),
            backupAlbumProvider.overrideWith((ref) => _BackupAlbums()),
            backupProvider.overrideWith((ref) => _Backup()),
            appConfigProvider.overrideWithValue(const AppConfig()),
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
  }

  final banner = find.byType(FoldersBanner);
  final entry = find.byKey(const Key('desktop_folders_entry'));

  group('Library > On this computer', () {
    testWidgets('asks for a first folder, which opens the folders page', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPage(tester, const LocalAlbumsPage());

      expect(find.text('On this computer'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
      expect(banner, findsOneWidget);
      expect(find.text('It looks like you do not have any albums yet.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_folders_open')));
      await tester.pumpAndSettle();
      expect(find.text('folders page'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('with folders, one line to the folders page instead of the banner', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pumpPage(tester, const LocalAlbumsPage(), hasFolders: true);

      expect(banner, findsNothing);
      expect(entry, findsOneWidget);
      expect(find.text('Folders on this computer'), findsOneWidget);

      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('folders page'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('nothing while the library loads', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpPage(tester, const LocalAlbumsPage(), hasFolders: null);

      expect(banner, findsNothing);
      expect(entry, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps "On this device" and no folders', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpPage(tester, const LocalAlbumsPage());

      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('On this computer'), findsNothing);
      expect(banner, findsNothing);
      expect(entry, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the albums chosen for backup', () {
    testWidgets('ask for a first folder on a computer', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPage(tester, const BackupAlbumSelectionPage());

      expect(banner, findsOneWidget);
      expect(find.text('No albums found'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_folders_open')));
      await tester.pumpAndSettle();
      expect(find.text('folders page'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('offer the folders page once there are folders', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPage(tester, const BackupAlbumSelectionPage(), hasFolders: true);

      expect(banner, findsNothing);
      expect(entry, findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone has neither', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pumpPage(tester, const BackupAlbumSelectionPage());

      expect(banner, findsNothing);
      expect(entry, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
