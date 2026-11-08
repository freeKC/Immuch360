import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_failure_panel.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../widget_tester_extensions.dart';

void main() {
  // The 5.7K export of an Insta360 camera, which a TV decodes up to 4096 x 2304
  const probe57k = SphericalProbe(codec: 'avc1', codedWidth: 5760, codedHeight: 2880, frameRate: 30);
  final refused = DecodeVerdict(supported: false, hardware: true, maxWidth: 4096, maxHeight: 2304);
  final accepted = DecodeVerdict(supported: true, hardware: true, maxWidth: 4096, maxHeight: 2304);
  const error = VideoPlaybackFailure(VideoFailureKind.error, 'Decoder init failed: OMX.amlogic.avc.decoder.awesome');
  const stalled = VideoPlaybackFailure(VideoFailureKind.stalled);

  // The translations are loaded by the app around a widget
  Future<Translations> translations(WidgetTester tester) async {
    await tester.pumpConsumerWidget(const SizedBox());
    return StaticTranslations.instance;
  }

  VideoFailureText describe(
    Translations t,
    VideoPlaybackFailure failure, {
    SphericalProbe? probe,
    DecodeVerdict? verdict,
    VideoBitRate? bitRate,
    bool fromServer = true,
    bool remote = false,
  }) => describeVideoFailure(
    failure,
    (probe: probe, verdict: verdict, bitRate: bitRate),
    t,
    fromServer: fromServer,
    locale: 'en',
    remote: remote,
  );

  testWidgets('names the decoders of the device when the file is beyond them, with the server advice', (tester) async {
    final t = await translations(tester);

    final text = describe(t, error, probe: probe57k, verdict: refused);

    expect(text.title, 'This video cannot be played');
    expect(text.cause, 'H.264 5760 x 2880 is beyond the video decoders of this device (at most 4096 x 2304)');
    expect(text.advice, [t.video_failed_server_hint, t.video_failed_retry_hint]);
  });

  testWidgets('with a remote, the advice names the Info key and the Logs page, not the menu a TV does not show', (
    tester,
  ) async {
    final t = await translations(tester);

    expect(describe(t, error, probe: probe57k, verdict: refused, remote: true).advice, [
      t.video_failed_server_hint,
      t.video_failed_retry_hint_tv,
    ]);
    expect(describe(t, stalled, remote: true).advice, [t.video_failed_retry_hint_tv]);
    expect(t.video_failed_retry_hint_tv, isNot(contains('menu at the top')));
  });

  testWidgets('a stall of a file beyond the decoders is the decoder, not the network', (tester) async {
    final t = await translations(tester);

    final text = describe(t, stalled, probe: probe57k, verdict: refused);

    expect(text.title, 'This video cannot be played');
    expect(text.cause, startsWith('H.264 5760 x 2880 is beyond'));
  });

  testWidgets('a failure of the AV2 decoder of a computer is said in the words of the app', (tester) async {
    final t = await translations(tester);
    const stopped = Av2DecoderStopped('it crashed (code 0xC0000005): error decoding frame 3');
    const refused = Av2FormatRefused('4:2:2 10-bit');
    const slow = Av2TooSlow(fps: 5.9, needed: 24, key: '/a.ivf');

    // The companion stopped while the video played; the others refused the source before the player opened it
    final cases = {
      stopped.message: t.av2_error_decoder_stopped(reason: stopped.reason),
      'This video cannot be played on the computer: ${refused.message}': t.av2_error_format(format: '4:2:2 10-bit'),
      'This video cannot be played on the computer: ${slow.message}': t.av2_too_slow(fps: '6', needed: '24'),
      'This video cannot be played on the computer: ${const Av2TurnedOff().message}': t.av2_error_off,
    };
    for (final MapEntry(key: message, value: said) in cases.entries) {
      final text = describe(t, VideoPlaybackFailure(VideoFailureKind.error, message), fromServer: false);
      expect(text.title, 'This video cannot be played');
      expect(text.cause, said, reason: message);
      expect(text.advice, [t.video_failed_retry_hint]);
    }
    expect(const Av2TurnedOff().message, t.av2_error_off, reason: 'the English text of the app');
    expect(av2FailureText('The video could not be opened: <url>', t), isNull);
  });

  testWidgets('no server advice for a copy on the device', (tester) async {
    final t = await translations(tester);

    final text = describe(t, error, probe: probe57k, verdict: refused, fromServer: false);

    expect(text.advice, [t.video_failed_retry_hint]);
  });

  testWidgets('a codec without any decoder', (tester) async {
    final t = await translations(tester);

    final text = describe(
      t,
      error,
      probe: const SphericalProbe(codec: 'av01', codedWidth: 3840, codedHeight: 1920),
      verdict: DecodeVerdict(supported: false, hardware: false, maxWidth: 0, maxHeight: 0),
    );

    expect(text.cause, 'No video decoder of this device plays AV1');
  });

  testWidgets('a stall says what was measured only: never the bit rate of the file as a cause', (tester) async {
    final t = await translations(tester);

    // A player that tells nothing of its link (iOS), after a minute without a frame: the file of 104 Mbit/s is no cause
    final text = describe(
      t,
      stalled,
      probe: probe57k,
      verdict: accepted,
      bitRate: (bitsPerSecond: 104000000, source: VideoBitRateSource.videoTracks),
    );

    expect(text.title, 'This video is not loading');
    expect(text.cause, 'Nothing of it played for a minute. It plays on as soon as it loads');
    expect(text.advice, [t.video_failed_retry_hint]);
    expect(text.cause, isNot(contains('104')));
  });

  testWidgets('a link that stopped sending says so, and that the video plays on by itself', (tester) async {
    final t = await translations(tester);
    const dead = VideoPlaybackFailure(VideoFailureKind.dead);

    final server = describe(t, dead, bitRate: (bitsPerSecond: 8000000, source: VideoBitRateSource.videoTracks));
    expect(server.title, 'This video is not loading');
    expect(server.cause, 'The server stopped sending this video');
    expect(server.advice, ['It plays on as soon as the server answers']);

    final share = describe(t, dead, fromServer: false);
    expect(share.cause, 'The share stopped sending this video');
    expect(share.advice, ['It plays on as soon as the share answers']);
  });

  testWidgets('the panel of a dead link has the hourglass, and no word of the network being too slow', (tester) async {
    await tester.pumpConsumerWidget(
      VideoFailurePanel(
        asset: RemoteAssetFactory.create(type: .video),
        failure: const VideoPlaybackFailure(VideoFailureKind.dead),
        fromServer: true,
      ),
      overrides: [
        videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.hourglass_empty_rounded), findsOneWidget);
    expect(find.text('The server stopped sending this video'), findsOneWidget);
    expect(find.textContaining('too slowly'), findsNothing);
  });

  testWidgets('an error of a decodable file, or of an unknown one, gives the message of the player', (tester) async {
    final t = await translations(tester);

    expect(describe(t, error, probe: probe57k, verdict: accepted).cause, error.message);
    expect(describe(t, const VideoPlaybackFailure(VideoFailureKind.error, '  ')).cause, isNull);
  });

  group('the decoder of 30 October', () {
    // The flat player on a Quest 3: the server's copy H.264 5760 x 2880, the stuck playing check of Media3 after 10 s,
    // while the probe of the original (HEVC) says it decodes
    const hevcOriginal = SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
    final hevcDecodes = DecodeVerdict(supported: true, hardware: true, maxWidth: 8192, maxHeight: 4320);
    const stuck = VideoPlaybackFailure(VideoFailureKind.error, 'immuch360-playback-error:noFrame:video/avc:5760:2880');
    const refusal = VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304);

    testWidgets('the stuck check of Media3 is said in our words, with the codec and the size of what played', (
      tester,
    ) async {
      final t = await translations(tester);

      final text = describe(t, stuck, probe: hevcOriginal, verdict: hevcDecodes);

      expect(text.title, 'This video cannot be played');
      expect(
        text.cause,
        'This video does not play: the decoder of this device gives no picture for it (H.264 5760 x 2880)',
      );
      expect(text.advice, [t.video_failed_server_hint, t.video_failed_retry_hint]);
      expect('${text.title} ${text.cause} ${text.advice}', isNot(contains('Player stuck')));
    });

    testWidgets('the text of Media3 never shows, should it come without the token', (tester) async {
      final t = await translations(tester);

      final text = describe(
        t,
        const VideoPlaybackFailure(VideoFailureKind.error, 'Player stuck playing with no progress for 10000 ms'),
      );

      expect(text.title, 'This video cannot be played');
      expect(text.cause, isNull);
    });

    testWidgets('a video nothing on the server decodes says so at once, with what to change in Immich', (tester) async {
      final t = await translations(tester);

      final text = describe(t, const VideoPlaybackFailure(VideoFailureKind.refused, null, refusal));

      expect(text.title, 'This video cannot be played');
      expect(
        text.cause,
        'This device cannot decode this video (H.264 5760 x 2880, above 4096 x 2304): in Immich, set the video '
        'transcoding to HEVC or lower the resolution',
      );
      expect(text.advice, [t.video_failed_retry_hint]);
    });

    testWidgets('a decoder that refused and a video too slow to come are said in our words too', (tester) async {
      final t = await translations(tester);

      expect(
        describe(t, const VideoPlaybackFailure(.error, 'immuch360-playback-error:decoder:video/hevc:7680:3840')).cause,
        'This device cannot decode this video (HEVC 7680 x 3840)',
      );
      // The player tried for as long as its link brought nothing (10 minutes), then stopped
      final slow = describe(t, const VideoPlaybackFailure(.error, 'immuch360-playback-error:stalled::0:0'));
      expect(slow.title, 'This video is not loading');
      expect(slow.cause, 'The server stopped sending this video');
      final stopped = describe(t, const VideoPlaybackFailure(.error, 'immuch360-playback-error:stopped::0:0'));
      expect(stopped.title, 'This video cannot be played');
      expect(stopped.cause, isNull);
    });

    testWidgets('the panel shows the refusal, and the notice of the copy reads as asked', (tester) async {
      await tester.pumpConsumerWidget(
        Builder(
          builder: (context) => VideoFailurePanel(
            asset: RemoteAssetFactory.create(type: .video),
            failure: const VideoPlaybackFailure(VideoFailureKind.refused, null, refusal),
            fromServer: true,
          ),
        ),
        overrides: [
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('This video cannot be played'), findsOneWidget);
      expect(find.textContaining('above 4096 x 2304): in Immich, set the video transcoding to HEVC'), findsOneWidget);
      final t = StaticTranslations.instance;
      expect(
        const VideoSourceNotice(.switched, codec: 'H.264', width: 5760, height: 2880).message(t),
        "Playing the server's copy: the original (H.264 5760 x 2880) is above this device's decoder",
      );
      expect(
        const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880).message(t),
        "Playing the original: the server's copy (H.264 5760 x 2880) is above this device's decoder",
      );
      expect(
        const VideoSourceNotice(.copyForced, codec: 'H.264', width: 5760, height: 2880).message(t),
        "Playing the server's copy although it is above this device's decoder (H.264 5760 x 2880)",
      );
    });
  });

  group('a decoder that refused the original while it played (a TV, 8 November 2026)', () {
    // The decoder check accepted the HEVC original, the decoder refused it, and the server's copy is beyond the
    // decoders too: no switch, and the panel says what to change in Immich
    const refusedWithCopyBeyond = VideoPlaybackFailure(
      VideoFailureKind.error,
      'immuch360-playback-error:decoder:video/hevc:5760:2880',
      VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304),
    );
    const copyLine =
        "The server's copy (H.264 5760 x 2880) is beyond the decoders of this device too: in Immich, lower the target "
        'resolution of the video transcoding, then run Transcode videos';

    testWidgets("names the server's copy beyond the decoders in place of the server advice", (tester) async {
      final t = await translations(tester);

      final text = describe(t, refusedWithCopyBeyond);

      expect(text.title, 'This video cannot be played');
      expect(text.cause, 'This device cannot decode this video (HEVC 5760 x 2880)');
      expect(text.advice, [copyLine, t.video_failed_retry_hint]);
      expect(text.advice, isNot(contains(t.video_failed_server_hint)));
    });

    testWidgets('the panel shows the copy line, and the notices of a switch read as asked', (tester) async {
      await tester.pumpConsumerWidget(
        Builder(
          builder: (context) => VideoFailurePanel(
            asset: RemoteAssetFactory.create(type: .video),
            failure: refusedWithCopyBeyond,
            fromServer: true,
          ),
        ),
        overrides: [
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('This device cannot decode this video (HEVC 5760 x 2880)'), findsOneWidget);
      expect(find.text(copyLine), findsOneWidget);
      final t = StaticTranslations.instance;
      expect(find.text(t.video_failed_server_hint), findsNothing);
      expect(
        const VideoSourceNotice(.copyAfterRefusal, codec: 'HEVC', width: 5760, height: 2880).message(t),
        "Playing the server's copy: the original (HEVC 5760 x 2880) was refused by this device's decoder",
      );
      expect(
        const VideoSourceNotice(.originalAfterRefusal, codec: 'H.264', width: 1920, height: 960).message(t),
        "Playing the original: the server's copy (H.264 1920 x 960) was refused by this device's decoder",
      );
    });
  });

  group('the 360° player of a video beyond the decoders', () {
    Future<Future<bool>> openDialog(WidgetTester tester) async {
      late Future<bool> answer;
      await tester.pumpConsumerWidget(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = confirmUndecodableVideo(context, probe57k, refused),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('says why and how the server can help, Close focused', (tester) async {
      final answer = await openDialog(tester);

      expect(find.byKey(const Key('undecodable_video_dialog')), findsOneWidget);
      expect(find.textContaining('H.264 5760 x 2880 is beyond the video decoders'), findsOneWidget);
      expect(find.textContaining('Transcode videos'), findsOneWidget);
      final close = find.widgetWithText(TextButton, StaticTranslations.instance.close);
      expect(Focus.of(tester.element(find.descendant(of: close, matching: find.byType(Text)))).hasFocus, isTrue);

      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });

    testWidgets('Play still opens it', (tester) async {
      final answer = await openDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, StaticTranslations.instance.play));
      await tester.pumpAndSettle();

      expect(await answer, isTrue);
    });
  });
}
