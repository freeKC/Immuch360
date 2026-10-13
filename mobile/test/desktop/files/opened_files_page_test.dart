// The page of the files opened with the program at once (lib/desktop/files/opened_files.page.dart): a wait while they
// are read, their grid under the name of their folder or their count, and what it says when none is a photo or a
// video.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/files/opened_files.page.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:mocktail/mocktail.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

OpenedFile _photo(String name) => OpenedFile(
  file: LibraryFile(
    assetId: 'f-$name',
    path: '/photos/$name',
    name: name,
    kind: LibraryMediaKind.image,
    size: 1,
    modifiedMs: 0,
    createdSeconds: 0,
    mimeType: 'image/jpeg',
    cloudOnly: false,
    available: true,
  ),
  asset: LocalAsset(
    id: 'f-$name',
    name: name,
    type: AssetType.image,
    createdAt: DateTime.utc(2026, 10, 13),
    updatedAt: DateTime.utc(2026, 10, 13),
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
  ),
  record: LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime.utc(2026)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockTimelineFactory timelines;
  final shown = <List<BaseAsset>>[];

  setUpAll(() {
    registerFallbackValue(<BaseAsset>[]);
    registerFallbackValue(TimelineOrigin.deepLink);
  });

  setUp(() {
    shown.clear();
    timelines = _MockTimelineFactory();
    when(() => timelines.fromAssetsWithBuckets(any(), any())).thenAnswer((call) {
      final assets = call.positionalArguments[0] as List<BaseAsset>;
      shown.add(assets);
      return TimelineService((
        assetSource: (i, n) async => assets.sublist(i, math.min(i + n, assets.length)),
        bucketSource: () => Stream.value([TimeBucket(date: DateTime(2026, 10, 13), assetCount: assets.length)]),
        origin: call.positionalArguments[1] as TimelineOrigin,
      ));
    });
  });

  Future<void> pumpPage(WidgetTester tester, Future<OpenedBatch> files, {String? title}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          initial: true,
          page: PageInfo(
            'Opened',
            builder: (_) => OpenedFilesPage(title: title, files: files),
          ),
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
        child: Builder(
          builder: (context) => ProviderScope(
            overrides: [
              timelineFactoryProvider.overrideWithValue(timelines),
              appConfigProvider.overrideWithValue(const AppConfig()),
            ],
            child: MaterialApp.router(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(navigatorObservers: () => [TransitioningRouteObserver()]),
            ),
          ),
        ),
      ),
    );
    // The translations load first
    for (var i = 0; i < 50 && find.byType(OpenedFilesPage).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
  }

  /// The texts on screen, for the messages of a failed expectation
  String texts() => find.byType(Text).evaluate().map((element) => (element.widget as Text).data).join(' | ');

  testWidgets('waits while the files are read, under the name of their folder', (tester) async {
    final reading = Completer<OpenedBatch>();

    await pumpPage(tester, reading.future, title: 'DCIM');

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('DCIM'), findsOneWidget);
    reading.complete(const OpenedBatch([], fromFolder: true));
    await tester.pumpAndSettle();
  });

  testWidgets('shows the photos and videos as a timeline of their own, by date', (tester) async {
    await pumpPage(
      tester,
      Future.value(OpenedBatch([_photo('IMG_1.jpg'), _photo('IMG_2.jpg')], fromFolder: true)),
      title: 'Trip',
    );
    await tester.pump();
    await tester.pump();
    // Thumbnails cannot load here
    tester.takeException();

    expect(find.byType(Timeline), findsOneWidget);
    expect(shown.single.map((asset) => asset.id), ['f-IMG_1.jpg', 'f-IMG_2.jpg']);
    verify(() => timelines.fromAssetsWithBuckets(any(), TimelineOrigin.deepLink)).called(1);
    // The timers of the grid run out
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
  });

  testWidgets('counts the files of several folders for its title', (tester) async {
    await pumpPage(tester, Future.value(OpenedBatch([_photo('a.jpg'), _photo('b.jpg')], fromFolder: false)));
    await tester.pump();
    await tester.pump();
    tester.takeException();

    expect(find.text('2 items'), findsWidgets, reason: texts());
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
  });

  testWidgets('says a folder without photos or videos is empty, and so for files that are none', (tester) async {
    await pumpPage(tester, Future.value(const OpenedBatch([], fromFolder: true)), title: 'Documents');
    await tester.pumpAndSettle();
    expect(find.text('This folder is empty'), findsOneWidget);

    await pumpPage(tester, Future.value(const OpenedBatch([], fromFolder: false)), title: 'Documents');
    await tester.pumpAndSettle();
    expect(find.text('No assets to show'), findsOneWidget);
  });
}
