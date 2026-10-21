import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_failure_panel.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

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
  }) => describeVideoFailure(
    failure,
    (probe: probe, verdict: verdict, bitRate: bitRate),
    t,
    fromServer: fromServer,
    locale: 'en',
  );

  testWidgets('names the decoders of the device when the file is beyond them, with the server advice', (tester) async {
    final t = await translations(tester);

    final text = describe(t, error, probe: probe57k, verdict: refused);

    expect(text.title, 'This video cannot be played');
    expect(text.cause, 'H.264 5760 x 2880 is beyond the video decoders of this device (at most 4096 x 2304)');
    expect(text.advice, [t.video_failed_server_hint, t.video_failed_retry_hint]);
  });

  testWidgets('a stall of a file beyond the decoders is the decoder, not the network', (tester) async {
    final t = await translations(tester);

    final text = describe(t, stalled, probe: probe57k, verdict: refused);

    expect(text.title, 'This video cannot be played');
    expect(text.cause, startsWith('H.264 5760 x 2880 is beyond'));
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

  testWidgets('a stall of a decodable file gives its bit rate', (tester) async {
    final t = await translations(tester);

    final text = describe(
      t,
      stalled,
      probe: probe57k,
      verdict: accepted,
      bitRate: (bitsPerSecond: 104000000, source: VideoBitRateSource.videoTracks),
    );

    expect(text.title, 'This video is not loading');
    expect(text.cause, 'Its bit rate, 104 Mbit/s, may be more than the network or the server delivers');
    expect(text.advice, [t.video_failed_retry_hint]);
  });

  testWidgets('a stall without a known bit rate blames the network or the server', (tester) async {
    final t = await translations(tester);

    final text = describe(t, stalled);

    expect(text.cause, 'The network or the server sends it too slowly');
  });

  testWidgets('an error of a decodable file, or of an unknown one, gives the message of the player', (tester) async {
    final t = await translations(tester);

    expect(describe(t, error, probe: probe57k, verdict: accepted).cause, error.message);
    expect(describe(t, const VideoPlaybackFailure(VideoFailureKind.error, '  ')).cause, isNull);
  });
}
