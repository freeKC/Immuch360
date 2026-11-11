// The audio track and subtitle menus of the flat player of the phones, TVs and headsets: shown for a video with two
// audio tracks or more, or with subtitles, reached with the remote, and what they ask of the player; for a film of a
// media server, the names it gives the tracks and what it hears of a pick.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_track_buttons.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_controls.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';
import 'package:native_video_player/native_video_player.dart';

const _english = NativeVideoTrack(
  type: NativeVideoTrackType.audio,
  groupIndex: 1,
  trackIndex: 0,
  language: 'en',
  languageName: 'English',
  channels: 2,
  selected: true,
  isDefault: true,
);
const _french = NativeVideoTrack(
  type: NativeVideoTrackType.audio,
  groupIndex: 2,
  trackIndex: 0,
  language: 'fr',
  languageName: 'French',
  channels: 6,
);
const _subtitles = NativeVideoTrack(
  type: NativeVideoTrackType.text,
  groupIndex: 3,
  trackIndex: 0,
  language: 'fr',
  languageName: 'French',
);
const _forced = NativeVideoTrack(
  type: NativeVideoTrackType.text,
  groupIndex: 4,
  trackIndex: 0,
  language: 'en',
  languageName: 'English',
  isForced: true,
);

/// A side file of subtitles the app gave the player, as Media3 lists it once merged with the film
const _sidecar = NativeVideoTrack(
  type: NativeVideoTrackType.text,
  groupIndex: 5,
  trackIndex: 0,
  language: 'fr',
  languageName: 'French',
  label: 'Film.fr.srt',
  id: '1:immuch-sub-7',
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

/// A player whose tracks are [listed], recording what is asked of it
class _TrackPlayer extends VideoPlayerNotifier {
  _TrackPlayer(this.listed, this.calls) {
    state = const VideoPlayerState(
      position: Duration(seconds: 30),
      duration: Duration(minutes: 2),
      status: VideoPlaybackStatus.paused,
    );
  }

  List<NativeVideoTrack> listed;
  final List<String> calls;
  final locales = <String?>[];

  /// Holds the listings until completed, when set: a native player that answers late
  Completer<void>? gate;

  @override
  List<NativeVideoTrack> lastTracks = const [];

  @override
  Future<List<NativeVideoTrack>> tracks({String? locale}) async {
    locales.add(locale);
    await gate?.future;
    return lastTracks = listed;
  }

  @override
  Future<void> selectTrack(NativeVideoTrack track) async => calls.add('select ${track.type.name} ${track.groupIndex}');

  @override
  Future<void> disableTracks(NativeVideoTrackType type) async => calls.add('off ${type.name}');
}

void main() {
  late List<String> calls;
  late _TrackPlayer player;

  Future<void> pump(
    WidgetTester tester,
    List<NativeVideoTrack> tracks, {
    bool tvMode = false,
    ValueListenable<bool>? shown,
    VideoTrackNaming? naming,
  }) async {
    calls = [];
    player = _TrackPlayer(tracks, calls);
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
            videoPlayerProvider('film').overrideWith((ref) => player),
            tvModeProvider.overrideWithValue(tvMode),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // The remote control layout around the navigator, as in the app
              builder: tvMode ? (context, child) => TvShell(child: child!) : null,
              home: Scaffold(
                backgroundColor: Colors.black,
                body: Consumer(
                  builder: (context, ref, _) {
                    // The page keeps the player while the controls hide and show again
                    ref.watch(videoPlayerProvider('film'));
                    return ValueListenableBuilder<bool>(
                      valueListenable: shown ?? ValueNotifier(true),
                      builder: (context, show, _) => Align(
                        alignment: Alignment.bottomCenter,
                        child: show
                            ? NetworkVideoControls(playerKey: 'film', trackNaming: naming)
                            : const SizedBox.shrink(),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final audioMenu = find.byKey(const Key('video_audio_tracks'));
  final subtitleMenu = find.byKey(const Key('video_subtitles'));

  testWidgets('a film with two languages and subtitles: both menus, the languages named in the language of the app', (
    tester,
  ) async {
    await pump(tester, const [_english, _french, _subtitles, _forced]);
    expect(audioMenu, findsOneWidget);
    expect(subtitleMenu, findsOneWidget);
    expect(player.locales.last, 'en');

    await tester.tap(audioMenu);
    await tester.pumpAndSettle();
    expect(find.text('English, Stereo, Default'), findsOneWidget);
    expect(find.text('French, 5.1'), findsOneWidget);
    await tester.tap(find.text('French, 5.1'));
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2']);

    await tester.tap(subtitleMenu);
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('English, Forced'), findsOneWidget);
    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();
    await tester.tap(subtitleMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2', 'select text 3', 'off text']);
  });

  testWidgets('one audio track and no subtitles, or a player that lists none (iOS): no menu', (tester) async {
    await pump(tester, const [_english]);
    expect(audioMenu, findsNothing);
    expect(subtitleMenu, findsNothing);

    await pump(tester, const []);
    expect(find.byType(VideoTrackButtons), findsOneWidget);
    expect(audioMenu, findsNothing);
  });

  testWidgets('the menus follow the tracks the player reports once the video is loaded', (tester) async {
    await pump(tester, const []);
    expect(audioMenu, findsNothing);

    player.listed = const [_english, _french];
    player.onNativeTracksChanged();
    await tester.pumpAndSettle();
    expect(audioMenu, findsOneWidget);
    expect(subtitleMenu, findsNothing);
  });

  testWidgets('controls that show again have their menus at once, before the native player answers', (tester) async {
    final shown = ValueNotifier(true);
    await pump(tester, const [_english, _french, _subtitles], shown: shown);
    expect(audioMenu, findsOneWidget);

    shown.value = false;
    await tester.pump();
    player.gate = Completer<void>();
    shown.value = true;
    await tester.pump();
    expect(audioMenu, findsOneWidget);
    expect(subtitleMenu, findsOneWidget);

    player.gate!.complete();
    await tester.pumpAndSettle();
    expect(audioMenu, findsOneWidget);
  });

  testWidgets('on a TV the remote reaches them after +10 s, and OK picks a track', (tester) async {
    await pump(tester, const [_english, _french, _subtitles], tvMode: true);
    Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(const Key('network_video_play_pause')),
          matching: find.byType(AnimatedPlayPause),
        ),
      ),
    ).requestFocus();
    await tester.pump();

    // Play, -10 s, +10 s, then the audio menu
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(Focus.of(tester.element(find.byIcon(Icons.audiotrack_outlined))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('French, 5.1'), findsOneWidget);
    // The menu opens on the line of the track that plays, English; Down goes to the next line, which OK picks
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2']);
    expect(find.text('French, 5.1'), findsNothing, reason: 'the menu closed');

    // Right again: the subtitles, Off first, whose menu opens on Off
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(Focus.of(tester.element(find.byIcon(Icons.subtitles_outlined))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('Off'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2', 'select text 3']);
  });

  testWidgets('the names of the tracks: a track without language or name gets its number, Default only when alone', (
    tester,
  ) async {
    await pump(tester, const []);
    final t = tester.element(find.byType(VideoTrackButtons)).t;
    expect(
      videoTrackLabels(t, const [
        NativeVideoTrack(type: NativeVideoTrackType.audio, groupIndex: 0, trackIndex: 0, channels: 1, isDefault: true),
        NativeVideoTrack(
          type: NativeVideoTrackType.audio,
          groupIndex: 0,
          trackIndex: 1,
          language: 'de',
          label: "Director's commentary",
          channels: 8,
          isDefault: true,
        ),
        NativeVideoTrack(
          type: NativeVideoTrackType.audio,
          groupIndex: 1,
          trackIndex: 0,
          languageName: 'Japanese',
          label: 'japanese',
          channels: 4,
        ),
      ]),
      ['Track 1, Mono', "DE, Director's commentary, 7.1", 'Japanese, 4 channels'],
    );
  });

  testWidgets('a film of a media server: the names it gives, the player\'s own elsewhere, and each pick told', (
    tester,
  ) async {
    const frenchAudio = VideoTrackRef(kind: VideoTrackKind.audio, ordinal: 1, language: 'fr');
    const sidecar = VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: 'immuch-sub-7', language: 'fr');
    final naming = _Naming({frenchAudio: 'Français (AC3 5.1)', sidecar: 'Français (SRT)'});
    await pump(tester, const [_english, _french, _subtitles, _sidecar], naming: naming);

    await tester.tap(audioMenu);
    await tester.pumpAndSettle();
    expect(find.text('English, Stereo, Default'), findsOneWidget, reason: 'a track the server does not name');
    expect(find.text('Français (AC3 5.1)'), findsOneWidget);
    expect(find.text('French, 5.1'), findsNothing);
    await tester.tap(find.text('Français (AC3 5.1)'));
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2']);
    expect(naming.picks, [(VideoTrackKind.audio, frenchAudio)]);

    await tester.tap(subtitleMenu);
    await tester.pumpAndSettle();
    expect(find.text('French'), findsOneWidget, reason: 'the subtitles of the file, unnamed by the server');
    await tester.tap(find.text('Français (SRT)'));
    await tester.pumpAndSettle();
    await tester.tap(subtitleMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(calls, ['select audio 2', 'select text 5', 'off text']);
    expect(naming.picks, [
      (VideoTrackKind.audio, frenchAudio),
      (VideoTrackKind.subtitle, sidecar),
      (VideoTrackKind.subtitle, null),
    ]);
  });

  test('the tracks as a media server knows them: by their place in the file, a side file by its id', () {
    const second = NativeVideoTrack(type: NativeVideoTrackType.text, groupIndex: 6, trackIndex: 0, language: 'de');
    expect(videoTrackRefs(const [_subtitles, _sidecar, second]), const [
      VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: 0, language: 'fr'),
      VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: 'immuch-sub-7', language: 'fr'),
      VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: 1, language: 'de'),
    ]);
    expect(videoTrackRefs(const [_english, _french]), const [
      VideoTrackRef(kind: VideoTrackKind.audio, ordinal: 0, language: 'en'),
      VideoTrackRef(kind: VideoTrackKind.audio, ordinal: 1, language: 'fr'),
    ]);
  });

  test('a side file of subtitles goes to the player with the video, and comes back with its id', () {
    const subtitle = VideoSubtitle(
      uri: 'http://127.0.0.1:41000/token/plex/streams/12.srt',
      mimeType: 'application/x-subrip',
      language: 'fr',
      label: 'Français',
      id: 'immuch-sub-12',
    );
    expect(subtitle.toMap(), {
      'uri': 'http://127.0.0.1:41000/token/plex/streams/12.srt',
      'mimeType': 'application/x-subrip',
      'language': 'fr',
      'label': 'Français',
      'id': 'immuch-sub-12',
    });
    final source = VideoSource(
      path: 'http://127.0.0.1:41000/token/plex/film.mkv',
      type: VideoSourceType.network,
      headers: const {},
      subtitles: const [subtitle],
    );
    expect(source.toJson().containsKey('subtitles'), isFalse, reason: 'the API sends them itself');
    expect(
      NativeVideoTrack.fromMap({'type': 'text', 'group': 4, 'track': 0, 'id': '1:immuch-sub-12'})?.id,
      '1:immuch-sub-12',
    );
    expect(sidecarIdOfTrack('1:immuch-sub-12'), 'immuch-sub-12');
  });

  test('a track as the Android player sends it', () {
    expect(
      NativeVideoTrack.fromMap({
        'type': 'text',
        'group': 3,
        'track': 1,
        'language': 'fr',
        'languageName': 'Français',
        'label': null,
        'channels': 0,
        'selected': true,
        'isDefault': false,
        'isForced': true,
      }),
      const NativeVideoTrack(
        type: NativeVideoTrackType.text,
        groupIndex: 3,
        trackIndex: 1,
        language: 'fr',
        languageName: 'Français',
        selected: true,
        isForced: true,
      ),
    );
    expect(NativeVideoTrack.fromMap({'type': 'video', 'group': 0, 'track': 0}), isNull);
    expect(NativeVideoTrack.fromMap({'type': 'audio', 'group': '0', 'track': 0}), isNull);
  });
}
