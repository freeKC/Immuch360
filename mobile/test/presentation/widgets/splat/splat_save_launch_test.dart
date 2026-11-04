// Save to Immich in the app (lot L6, plan of 3 November 2026, sections 6.1 and 6.2): the saving of a viewing of the
// splat viewer (what the page gets in its session, the poster it posts, the save it starts and the state it reads),
// the scene of a splat photo that is on the server already, and the sheet of the Quest's splat page.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_save_launch.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/splat/splat_save.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';

import '../../../domain/splat_photo/splat_photo_fixtures.dart';
import '../../../domain/splat_photo/splat_save_fakes.dart';
import '../../../widget_tester_extensions.dart';

void main() {
  late Directory dir;
  late FakeSplatSaveServer server;
  late File spz;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('splat_save_launch');
    server = FakeSplatSaveServer();
    spz = File('${dir.path}/room.spz')..writeAsBytesSync(splatFixture('axes_v2.spz'));
    spz.setLastModifiedSync(DateTime.utc(2026, 11, 3, 15, 53));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<Override> overrides({bool connected = true}) => [
    appConfigProvider.overrideWithValue(const AppConfig()),
    splatSaveServerProvider.overrideWithValue(() => connected ? server : null),
    splatSaveRecordsProvider.overrideWithValue(SplatSaveRecords(() async => File('${dir.path}/splat_saves.json'))),
    splatSavePlyLimitProvider.overrideWithValue(() async => 1 << 30),
    splatSaveSoftwareProvider.overrideWith((ref) async => ('Immuch360 tests', 'Immuch360 tests (linux)')),
    splatSavePostersProvider.overrideWithValue((
      poster: (spz, head, up, mark) async => splatPhotoFixture('poster.jpg'),
      card: (name, line, mark) async => splatPhotoFixture('poster.jpg'),
    )),
    splatViewerCacheProvider.overrideWithValue(SplatViewerCache(() async => Directory('${dir.path}/cache'))),
  ];

  SplatHead headOf(File file) => probeSplatHead(file.readAsBytesSync(), file.lengthSync()) as SplatHead;

  testWidgets('the viewer: the page gets its texts, posts the view, saves, and reads where the save stands', (
    tester,
  ) async {
    late SplatViewerSaveSession saving;
    await tester.pumpConsumerWidget(
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () async {
            saving = SplatViewerSaveSession(
              container: ProviderScope.containerOf(context, listen: false),
              t: context.t,
              locale: 'en',
              scene: SplatSaveScene(path: spz.path, length: spz.lengthSync()),
              head: headOf(spz),
              onServer: false,
              connected: true,
              albumOn: true,
              up: null,
            );
          },
          child: const Text('open'),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.text('open'));
    await tester.pump();

    final session = saving.session;
    expect(session['offered'], isTrue);
    expect(session['connected'], isTrue);
    expect(session['mark'], isTrue);
    expect(session['name'], 'room.spz');
    expect(session['date'], 'In your timeline on Nov 3, 2026');
    expect((session['texts']! as Map)['save'], 'Save to Immich');
    expect((session['texts']! as Map)['album'], 'Add it to the album Splat scenes');

    expect(saving.takePoster(splatPhotoFixture('poster_motion.jpg')), isTrue);
    saving.upright('zUp');
    await tester.runAsync(() async {
      saving.onEvent(const SplatViewerSave(album: true));
      for (var i = 0; i < 100 && saving.state()['state'] != 'done'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    final state = saving.state();
    expect(state['state'], 'done', reason: '$state');
    expect(state['text'], 'Saved to Immich, in your timeline on Nov 3, 2026');
    expect(state['assetId'], 'asset-1');
    final xmp = SplatPhotoXmp.findIn(server.uploads.single.body)!;
    expect(xmp.splatPoster, SplatPosterKind.view);
    expect(xmp.splatUp, 'zUp');
    expect(xmp.creatorTool, 'Immuch360 tests (linux)');
    expect(server.albums.values.single, ['asset-1']);
  });

  testWidgets('the scene of a splat photo: on the server already, no poster taken', (tester) async {
    late SplatViewerSaveSession saving;
    await tester.pumpConsumerWidget(
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => saving = SplatViewerSaveSession(
            container: ProviderScope.containerOf(context, listen: false),
            t: context.t,
            locale: 'en',
            scene: SplatSaveScene(path: spz.path, length: spz.lengthSync()),
            head: headOf(spz),
            onServer: true,
            connected: true,
            albumOn: true,
            up: null,
          ),
          child: const Text('open'),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(saving.session['offered'], isFalse);
    expect(saving.session['onServer'], isTrue);
    expect((saving.session['texts']! as Map)['onServer'], 'On your Immich server');
    expect(saving.takePoster(splatPhotoFixture('poster.jpg')), isFalse);
  });

  testWidgets('the sheet: the drawn poster, the album switch remembered, Save, then the result', (tester) async {
    await tester.pumpConsumerWidget(
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => showSplatSaveSheet(context, ref, SplatSaveScene(path: spz.path, length: spz.lengthSync())),
          child: const Text('open'),
        ),
      ),
      overrides: overrides(),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // The sheet is built, then its poster comes from the drawing that started with the tap
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Save this scene to Immich'), findsOneWidget);
    expect(find.text('room.spz'), findsOneWidget);
    expect(find.text('Splat scene, 686 gaussians, 913 B'), findsOneWidget);

    await tester.tap(find.byKey(splatSaveSheetAlbumKey));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(splatSaveSheetSaveKey));
      for (var i = 0; i < 100 && server.uploads.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('Saved to Immich, in your timeline on Nov 3, 2026'), findsOneWidget);
    expect(server.albums, isEmpty, reason: 'the album switch was turned off');
    expect(SplatPhotoXmp.findIn(server.uploads.single.body)!.splatPoster, SplatPosterKind.render);
    final remembered = await tester.runAsync(
      () => SplatSaveRecords(() async => File('${dir.path}/splat_saves.json')).albumOn(),
    );
    expect(remembered, isFalse);
  });

  testWidgets('the sheet without a server says to connect one', (tester) async {
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => showSplatSaveSheet(context, ref, SplatSaveScene(path: spz.path, length: spz.lengthSync())),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(connected: false),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to an Immich server to upload'), findsOneWidget);
    expect(find.text('Save this scene to Immich'), findsNothing);
  });
}
