// The "Downloaded films" page: the copies with their state, the room they take, the Wi-Fi switch, the delete of one
// copy and of all of them, and the empty list. The list is read from a temporary folder before the page shows.

import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/network/downloaded_films.page.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';

import '../../../providers/network/film_download_fakes.dart';

void main() {
  late Directory root;
  late FakeFilmEnvironment fake;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('downloaded_films_page_test');
    fake = FakeFilmEnvironment(root, FakeDownloadShare({}));
  });
  tearDown(() async {
    await fake.close();
    await root.delete(recursive: true);
  });

  FilmDownload film(
    String id,
    String title,
    FilmDownloadState state, {
    int received = 0,
    FilmDownloadFailure? failure,
  }) => FilmDownload(
    id: id,
    sourceId: filmTestSource.id,
    path: '/Movies/$title.mkv',
    fileName: '$title.mkv',
    title: title,
    localPath: '${fake.films.path}${Platform.pathSeparator}$id.mkv',
    state: state,
    addedAt: DateTime.utc(2026, 11, 10),
    size: 2 * 1024 * 1024,
    identity: 'id:$id',
    received: received,
    failure: failure,
  );

  /// Writes [films] as the kept list, with their files, and reads it into a container
  Future<ProviderContainer> seed(WidgetTester tester, List<FilmDownload> films) async {
    final container = ProviderContainer(
      overrides: [filmDownloadEnvironmentProvider.overrideWithValue(fake.environment)],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final index = Directory('${root.path}${Platform.pathSeparator}index');
      await index.create(recursive: true);
      await fake.films.create(recursive: true);
      for (final item in films) {
        if (item.isDone) {
          await File(item.localPath).writeAsBytes(List.filled(16, 1));
        } else if (item.received > 0) {
          await File('${item.localPath}.part').writeAsBytes(List.filled(item.received, 1));
        }
      }
      await File('${index.path}${Platform.pathSeparator}films.json').writeAsString(
        jsonEncode({
          'version': 1,
          'wifiOnly': true,
          'films': [for (final item in films) item.toJson()],
        }),
      );
      await container.read(filmDownloadsProvider.notifier).ready;
    });
    return container;
  }

  Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: UncontrolledProviderScope(
          container: container,
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const DownloadedFilmsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the copies with their state and the room they take', (tester) async {
    final container = await seed(tester, [
      film('a1', 'Heat', FilmDownloadState.done, received: 2 * 1024 * 1024),
      film('b2', 'Ronin', FilmDownloadState.paused, received: 1024 * 1024),
      film('c3', 'Collateral', FilmDownloadState.failed, failure: FilmDownloadFailure.forbidden),
    ]);
    await pumpPage(tester, container);

    expect(find.text('Heat'), findsOneWidget);
    expect(find.text('Ronin'), findsOneWidget);
    expect(find.text('Collateral'), findsOneWidget);
    expect(find.textContaining('Downloaded'), findsWidgets);
    expect(find.text('Paused · 1.0 MiB of 2.0 MiB'), findsOneWidget);
    expect(find.text('This Plex account may not download films'), findsOneWidget);
    // One whole film; the room counts the whole copy and the bytes of the paused one
    expect(find.text('1 film · 3.0 MiB on this device'), findsOneWidget);
    // A whole copy is deleted, a stopped one resumes or is cancelled
    expect(find.byKey(const Key('downloaded_film_delete_a1')), findsOneWidget);
    expect(find.byKey(const Key('downloaded_film_resume_b2')), findsOneWidget);
    expect(find.byKey(const Key('downloaded_film_cancel_b2')), findsOneWidget);
    expect(find.byKey(const Key('downloaded_film_resume_c3')), findsOneWidget);
  });

  testWidgets('Download only on Wi-Fi is on by default and turns off', (tester) async {
    final container = await seed(tester, const []);
    await pumpPage(tester, container);

    expect(find.byKey(const Key('downloaded_films_empty')), findsOneWidget);
    final wifiOnly = find.byKey(const Key('downloaded_films_wifi_only'));
    expect(tester.widget<SwitchListTile>(wifiOnly).value, isTrue);
    await tester.tap(wifiOnly);
    await tester.pumpAndSettle();
    expect(container.read(filmDownloadsProvider).wifiOnly, isFalse);
    expect(tester.widget<SwitchListTile>(wifiOnly).value, isFalse);
  });

  testWidgets('deleting a copy asks first, then takes it off the list', (tester) async {
    final container = await seed(tester, [film('a1', 'Heat', FilmDownloadState.done, received: 2 * 1024 * 1024)]);
    await pumpPage(tester, container);

    await tester.tap(find.byKey(const Key('downloaded_film_delete_a1')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Heat from this device? The film stays on the Plex server.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('film_download_delete_confirm')));
    await tester.pumpAndSettle();
    expect(container.read(filmDownloadsProvider).films, isEmpty);
    expect(find.text('Heat'), findsNothing);
    expect(find.byKey(const Key('downloaded_films_empty')), findsOneWidget);
  });

  testWidgets('delete all asks with the count', (tester) async {
    final container = await seed(tester, [
      film('a1', 'Heat', FilmDownloadState.done, received: 2 * 1024 * 1024),
      film('b2', 'Ronin', FilmDownloadState.done, received: 2 * 1024 * 1024),
    ]);
    await pumpPage(tester, container);

    await tester.tap(find.byKey(const Key('downloaded_films_delete_all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete the 2 downloaded films from this device? They stay on the Plex server.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('downloaded_films_delete_all_confirm')));
    await tester.pumpAndSettle();
    expect(container.read(filmDownloadsProvider).films, isEmpty);
  });
}
