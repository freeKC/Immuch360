// The film and series page of a Jellyfin or Emby server: a film with and without a place to resume, its streams
// line, Play from start; a series with its seasons, the progress and the tick of its episodes and Next episode; the
// focus on the first button on a TV; and the browser opening it on a tap on a film or a series.

import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/media_server_item.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/media_server_item.page.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import 'network_viewer_fakes.dart';

const _source = NetworkSource(id: 'jf', type: NetworkSourceType.jellyfin, name: 'Home media', host: '192.0.2.10');

const _film = MediaServerItem(
  id: 'film-1',
  kind: MediaServerItemKind.film,
  title: 'Stereo (2022)',
  year: 2022,
  durationMs: 90 * 60 * 1000,
  overview: 'Two patterns side by side.',
  positionMs: 62 * 1000,
  videoCodec: 'hevc',
  videoHeight: 1080,
  audio: [(codec: 'dts', channels: 6), (codec: 'aac', channels: 2)],
  stereo: 'HalfSideBySide',
);

const _series = MediaServerItem(id: 'series-1', kind: MediaServerItemKind.series, title: 'Pattern Show');
const _season1 = MediaServerItem(id: 's1', kind: MediaServerItemKind.season, title: 'Season 1', seasonNumber: 1);
const _season2 = MediaServerItem(id: 's2', kind: MediaServerItemKind.season, title: 'Season 2', seasonNumber: 2);
const _e1 = MediaServerItem(
  id: 'e1',
  kind: MediaServerItemKind.episode,
  title: 'Pilot',
  seasonNumber: 2,
  episodeNumber: 1,
  durationMs: 600000,
  played: true,
);
const _e2 = MediaServerItem(
  id: 'e2',
  kind: MediaServerItemKind.episode,
  title: 'Second',
  seasonNumber: 2,
  episodeNumber: 2,
  durationMs: 600000,
  positionMs: 300000,
);

class _ItemShare extends MemoryShare implements MediaServerItemSource {
  _ItemShare() : super(_source);

  final Map<String, MediaServerItem> items = {
    for (final item in [_film, _series, _season1, _season2, _e1, _e2]) item.id: item,
  };
  final Map<String, String> pages = {};
  MediaServerItem? next = _e2;

  @override
  String? itemPageAt(String path) => pages[path];

  @override
  Future<MediaServerItem> itemDetails(String itemId) async => items[itemId]!;

  @override
  Future<List<MediaServerItem>> seasonsOf(String seriesId) async => const [_season1, _season2];

  @override
  Future<List<MediaServerItem>> episodesOf(String seriesId, String seasonId) async =>
      seasonId == 's2' ? const [_e1, _e2] : const [];

  @override
  Future<MediaServerItem?> nextEpisodeOf(String seriesId) async => next;

  @override
  Future<String> pathOfItem(String itemId) async => '/.items/$itemId/m/file.mkv';

  @override
  Future<Uint8List?> itemPicture(String itemId, int size) async => null;
}

void main() {
  late Drift db;
  late StoreService store;
  late _ItemShare share;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList(const [_source]));
    share = _ItemShare();
    for (final path in ['/.items/film-1/m/file.mkv', '/.items/e2/m/file.mkv', '/Films/Stereo (2022) 3D.HSBS.mkv']) {
      share.files[path] = Uint8List(100);
    }
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<void> pumpItem(WidgetTester tester, String itemId, {String? path}) async {
    tester.view.physicalSize = const Size(1200, 3000);
    addTearDown(tester.view.resetPhysicalSize);
    await pumpNetworkRouter(
      tester,
      home: MediaServerItemPage(sourceId: _source.id, itemId: itemId, path: path),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a film: its title, streams, Resume at the server place, then Play from start', (tester) async {
    await pumpItem(tester, 'film-1');
    expect(find.text('Stereo (2022)'), findsWidgets);
    expect(find.text('HEVC 1080p, DTS 5.1, 2 audio tracks, half side by side 3D'), findsOneWidget);
    expect(find.text('Two patterns side by side.'), findsOneWidget);
    expect(find.text('Resume at 01:02'), findsOneWidget);
    final play = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Resume at 01:02'), matching: find.byType(FilledButton)),
    );
    expect(play.autofocus, isTrue, reason: 'the first stop of the remote on a TV');

    await tester.tap(find.text('Resume at 01:02'));
    await tester.pumpAndSettle();
    expect(find.text('video jf /.items/film-1/m/file.mkv'), findsOneWidget);
  });

  testWidgets('a film never started: Play only', (tester) async {
    share.items['film-1'] = const MediaServerItem(
      id: 'film-1',
      kind: MediaServerItemKind.film,
      title: 'Pattern',
      durationMs: 30000,
    );
    await pumpItem(tester, 'film-1');
    expect(find.text('Play'), findsOneWidget);
    expect(find.byKey(const Key('media_server_play_from_start')), findsNothing);
  });

  testWidgets('a series: Next episode, its season picked, the progress and the played tick', (tester) async {
    await pumpItem(tester, 'series-1');
    expect(find.text('Next episode: 2. Second'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('media_server_season_s2'))).selected, isTrue);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.byKey(const Key('media_server_played_e1')), findsOneWidget);
    expect(find.byKey(const Key('media_server_progress_e2')), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('media_server_progress_e2'))).value, 0.5);
    await tester.tap(find.byKey(const Key('media_server_season_s1')));
    await tester.pumpAndSettle();
    expect(find.text('No episodes in this season.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('media_server_next_episode')));
    await tester.pumpAndSettle();
    expect(find.text('video jf /.items/e2/m/file.mkv'), findsOneWidget);
  });

  testWidgets('a series without a next episode: the first season, its chip focused first', (tester) async {
    share.next = null;
    await pumpItem(tester, 'series-1');
    expect(find.byKey(const Key('media_server_next_episode')), findsNothing);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('media_server_season_s1'))).autofocus, isTrue);
  });
}
