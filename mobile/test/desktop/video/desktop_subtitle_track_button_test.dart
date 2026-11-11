// The subtitle menu of the flat player on the computers: shown for a video with subtitles in its file or side files
// of subtitles next to it, Off first, a side file added to the player the first time it is picked and shown by its
// track afterwards, and for a film of a media server, the names the server gives and what it hears of a pick. Then
// what DesktopPlayer reads of mpv's track list that media_kit leaves out.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_subtitle_track_button.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:native_video_player/native_video_player.dart';

import 'fake_playback_engine.dart';

const _bridgeUrl = 'http://127.0.0.1:41000/Zq8secretBridgeToken/plex-1/library/parts/7/file.mkv';
const _french = VideoSubtitle(
  uri: 'http://127.0.0.1:41000/Zq8secretBridgeToken/plex-1/library/streams/12.srt',
  mimeType: 'application/x-subrip',
  language: 'fr',
  label: 'Français (SRT)',
  id: 'immuch-sub-12',
);
const _german = VideoSubtitle(
  uri: 'http://127.0.0.1:41000/Zq8secretBridgeToken/plex-1/library/streams/13.srt',
  mimeType: 'application/x-subrip',
  language: 'de',
  id: 'immuch-sub-13',
);

/// A media server that names some tracks, recording the picks it hears of
class _Naming implements VideoTrackNaming {
  _Naming(this.labels);

  final Map<VideoTrackRef, String> labels;
  final picks = <(VideoTrackKind, VideoTrackRef?)>[];

  @override
  String? labelOf(VideoTrackRef track) => labels[track];

  @override
  void picked(VideoTrackKind kind, VideoTrackRef? track) => picks.add((kind, track));
}

void main() {
  final menu = find.byKey(const Key('desktop_subtitle_track'));

  /// A controller of a fake player that loaded [subtitles] with the film
  Future<(FakePlaybackEngine, MediaKitVideoPlayerController)> load(
    WidgetTester tester, {
    List<VideoSubtitle> subtitles = const [],
  }) async => (await tester.runAsync(() async {
    final players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 5));
    final controller = MediaKitVideoPlayerController(pool: players.pool, resolve: (source) async => source.path);
    await controller.loadVideoSource(
      await VideoSource.init(path: _bridgeUrl, type: VideoSourceType.network, subtitles: subtitles),
    );
    return (players.made.single, controller);
  }))!;

  Future<void> pump(WidgetTester tester, Widget child) async {
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
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: Row(children: [child])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Picks the line [label] of the subtitle menu, and lets the controller and the fake player answer
  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, label));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  testWidgets('shown for subtitles in the file or next to it, Off first, a side file added once when picked', (
    tester,
  ) async {
    final (engine, controller) = await load(tester, subtitles: const [_french, _german]);
    await pump(tester, DesktopSubtitleTrackButton(controller: controller));
    expect(menu, findsOneWidget, reason: 'side files only: the menu shows');

    engine.subtitleTracks.value = const [
      DesktopSubtitleTrack(id: '1', language: 'eng'),
      DesktopSubtitleTrack(id: '2', title: 'Director', language: 'eng'),
      DesktopSubtitleTrack(id: '3', language: 'fre', isForced: true),
    ];
    await tester.pump();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('ENG'), findsOneWidget);
    expect(find.text('Director'), findsOneWidget);
    expect(find.text('FRE · Forced'), findsOneWidget);
    expect(find.text('Français (SRT)'), findsOneWidget);
    expect(find.text('DE'), findsOneWidget, reason: 'a side file without a name: its language');
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, 'Français (SRT)'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(engine.calls.last, 'add subtitle ${_french.uri}');
    expect(controller.subtitleTrack.value, '10');

    // Now one of the tracks of the file, listed once, and shown by its track
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Français (SRT)'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, 'ENG'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await pick(tester, 'Français (SRT)');
    await pick(tester, 'Off');
    // A side file without a name keeps its line once added, which mpv names "external"
    await pick(tester, 'DE');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckedPopupMenuItem<int>, 'DE'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, 'Off'));
    await tester.pumpAndSettle();
    expect(engine.calls.where((call) => call.startsWith('add subtitle') || call.startsWith('subtitle')), [
      'add subtitle ${_french.uri}',
      'subtitle 1',
      'subtitle 10',
      'subtitle off',
      'add subtitle ${_german.uri}',
      'subtitle off',
    ]);
    await tester.runAsync(() async => controller.dispose());
  });

  testWidgets('nothing for a video without subtitles', (tester) async {
    final (_, controller) = await load(tester);
    await pump(tester, DesktopSubtitleTrackButton(controller: controller));
    expect(menu, findsNothing);
    await tester.runAsync(() async => controller.dispose());
  });

  testWidgets('a film of a media server: its names in both menus, and each pick told', (tester) async {
    final (engine, controller) = await load(tester, subtitles: const [_french]);
    const fileSubtitle = VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: 0, language: 'eng');
    const sidecar = VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: 'immuch-sub-12', language: 'fr');
    const commentary = VideoTrackRef(kind: VideoTrackKind.audio, ordinal: 1, language: 'eng');
    final naming = _Naming({
      fileSubtitle: 'English (PGS)',
      sidecar: 'Français (SRT, Plex)',
      commentary: 'English (Commentary, AC3 5.1)',
    });
    await pump(
      tester,
      Row(
        children: [
          DesktopAudioTrackButton(controller: controller, naming: naming),
          DesktopSubtitleTrackButton(controller: controller, naming: naming),
        ],
      ),
    );
    engine.audioTracks.value = const [
      DesktopAudioTrack(id: '1', language: 'eng', channels: 6),
      DesktopAudioTrack(id: '2', language: 'eng', title: 'Commentary', channels: 6),
    ];
    engine.subtitleTracks.value = const [DesktopSubtitleTrack(id: '3', language: 'eng')];
    await tester.pump();

    await tester.tap(find.byKey(const Key('desktop_audio_track')));
    await tester.pumpAndSettle();
    expect(find.text('ENG · 6 channels'), findsOneWidget, reason: 'a track the server does not name');
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'English (Commentary, AC3 5.1)'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(engine.calls.last, 'audio 2');

    await pick(tester, 'Français (SRT, Plex)');
    expect(engine.calls.last, 'add subtitle ${_french.uri}');
    // Added, the side file keeps the server's name, and the track of the file its own
    await pick(tester, 'English (PGS)');
    expect(engine.calls.last, 'subtitle 3');
    await pick(tester, 'Français (SRT, Plex)');
    expect(engine.calls.last, 'subtitle 10');
    await pick(tester, 'Off');
    expect(naming.picks, [
      (VideoTrackKind.audio, commentary),
      (VideoTrackKind.subtitle, sidecar),
      (VideoTrackKind.subtitle, fileSubtitle),
      (VideoTrackKind.subtitle, sidecar),
      (VideoTrackKind.subtitle, null),
    ]);
    await tester.runAsync(() async => controller.dispose());
  });

  test('what mpv\'s track list tells of the subtitles beyond media_kit: forced, and the side file added', () {
    final flags = subtitleTrackFlags(
      '[{"id":1,"type":"video","codec":"h264"},'
      '{"id":1,"type":"sub","lang":"eng","forced":false,"external":false},'
      '{"id":2,"type":"sub","lang":"fre","forced":true,"external":false},'
      '{"id":3,"type":"sub","title":"Français","external":true,"external-filename":"${_french.uri}"}]',
    );
    expect(flags, {
      '1': (forced: false, file: null),
      '2': (forced: true, file: null),
      '3': (forced: false, file: _french.uri),
    });
    expect(subtitleTrackFlags(''), isEmpty, reason: 'a libmpv that gives nothing');
    expect(subtitleTrackFlags('{"id":1}'), isEmpty);
  });

  test('a subtitle track does not print the address of its side file, which holds the bridge token', () {
    expect(
      DesktopSubtitleTrack(id: '10', language: 'fr', external: _french.uri).toString(),
      isNot(contains('Zq8secretBridgeToken')),
    );
  });
}
