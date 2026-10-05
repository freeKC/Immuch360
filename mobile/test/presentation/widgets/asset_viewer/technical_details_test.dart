import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  const probe = SphericalProbe(
    codec: 'hvc1',
    codecs: 'hvc1.1.6.L183',
    codedWidth: 7680,
    codedHeight: 3840,
    frameRate: 30000 / 1001,
  );

  Future<void> pumpDetails(WidgetTester tester, BaseAsset asset, VideoDecodeDetails details) => tester.pumpTestWidget(
    context,
    TechnicalDetails(asset: asset),
    overrides: [videoDecodeDetailsProvider(asset).overrideWith((ref) async => details)],
  );

  testWidgets('shows the codec, the coded size and the frame rate of a video, and that the device decodes it', (
    tester,
  ) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: DecodeVerdict(supported: true, hardware: true, maxWidth: 8192, maxHeight: 4320),
      bitRate: null,
    ));

    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('HEVC Main (hvc1.1.6.L183)  •  7680 x 3840  •  29.97 fps'), findsOneWidget);
    expect(find.text('Decodes on this device'), findsOneWidget);
    expect(find.text('Yes  •  Hardware  •  Up to 8192 x 4320'), findsOneWidget);
  });

  testWidgets('tells that the device does not decode a video, and its largest frame', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: DecodeVerdict(supported: false, hardware: true, maxWidth: 4096, maxHeight: 4096),
      bitRate: null,
    ));

    expect(find.text('No  •  Up to 4096 x 4096'), findsOneWidget);
  });

  testWidgets('tells which profile no decoder takes', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: DecodeVerdict(
        supported: false,
        hardware: false,
        maxWidth: 4096,
        maxHeight: 4096,
        profile: 'Main 10',
        missingProfile: 'Main 10',
      ),
      bitRate: null,
    ));

    expect(find.text('No  •  No decoder for Main 10  •  Up to 4096 x 4096'), findsOneWidget);
  });

  testWidgets('shows the bit rate of the video tracks', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: null,
      bitRate: (bitsPerSecond: 210000000, source: VideoBitRateSource.videoTracks),
    ));

    expect(find.text('Bit rate'), findsOneWidget);
    expect(find.text('210 Mbit/s'), findsOneWidget);
  });

  testWidgets('tells a bit rate of the whole file', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: null,
      bitRate: (bitsPerSecond: 67600000, source: VideoBitRateSource.mediaData),
    ));

    expect(find.text('68 Mbit/s  •  whole file, audio included'), findsOneWidget);
  });

  testWidgets('tells a bit rate estimated from the file size', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: null,
      bitRate: (bitsPerSecond: 4520000, source: VideoBitRateSource.fileSize),
    ));

    expect(find.text('4.5 Mbit/s  •  estimated from the file size'), findsOneWidget);
  });

  testWidgets('shows the bit depth, the HDR transfer and the primaries', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    const hlg = SphericalProbe(
      codec: 'hvc1',
      codecs: 'hvc1.2.4.L153',
      codedWidth: 5760,
      codedHeight: 2880,
      bitDepth: 10,
      transferCharacteristics: 18,
      colourPrimaries: 9,
    );
    await pumpDetails(tester, video, (probe: hlg, verdict: null, bitRate: null));

    expect(find.text('HEVC Main 10 (hvc1.2.4.L153)  •  5760 x 2880'), findsOneWidget);
    expect(find.text('Picture'), findsOneWidget);
    expect(find.text('10 bit  •  HDR, HLG  •  BT.2020'), findsOneWidget);
    expect(find.byIcon(Icons.hdr_on_outlined), findsOneWidget);
  });

  testWidgets('tells a Dolby Vision recording before its transfer', (tester) async {
    final iphone = RemoteAssetFactory.create(type: .video);
    const dolbyVision = SphericalProbe(
      codec: 'hvc1',
      codecs: 'hvc1.2.4.L153',
      bitDepth: 10,
      dolbyVision: true,
      transferCharacteristics: 18,
      colourPrimaries: 9,
    );
    await pumpDetails(tester, iphone, (probe: dolbyVision, verdict: null, bitRate: null));

    expect(find.text('10 bit  •  Dolby Vision  •  HDR, HLG  •  BT.2020'), findsOneWidget);
  });

  testWidgets('shows an SDR picture with the palette icon', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    const sdr = SphericalProbe(codec: 'avc1', bitDepth: 8, transferCharacteristics: 1, colourPrimaries: 1);
    await pumpDetails(tester, video, (probe: sdr, verdict: null, bitRate: null));

    expect(find.text('8 bit  •  SDR  •  BT.709'), findsOneWidget);
    expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
    expect(find.byIcon(Icons.hdr_on_outlined), findsNothing);
  });

  testWidgets('shows no picture and no bit rate when the file tells neither', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (probe: probe, verdict: null, bitRate: null));

    expect(find.text('Picture'), findsNothing);
    expect(find.text('Bit rate'), findsNothing);
  });

  testWidgets('shows the codec alone when the decoder check gave nothing', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (probe: probe, verdict: null, bitRate: null));

    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Decodes on this device'), findsNothing);
  });

  testWidgets('shows nothing of a video whose file could not be read', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (probe: null, verdict: null, bitRate: null));

    expect(find.text('Codec'), findsNothing);
  });

  testWidgets('shows nothing of the kind for a photo', (tester) async {
    final photo = RemoteAssetFactory.create();
    await pumpDetails(tester, photo, (probe: probe, verdict: null, bitRate: null));

    expect(find.text('Codec'), findsNothing);
  });

  test('sums the codec up with what the file tells of it', () {
    expect(videoCodecSummary(null), isNull);
    expect(videoCodecSummary(const SphericalProbe()), isNull);
    expect(videoCodecSummary(const SphericalProbe(codec: 'avc1')), 'H.264');
    expect(
      videoCodecSummary(
        const SphericalProbe(codec: 'av01', codecs: 'av01.0.13M.10', codedWidth: 3840, codedHeight: 2160),
      ),
      'AV1 Main (av01.0.13M.10)  •  3840 x 2160',
    );
    expect(
      videoCodecSummary(const SphericalProbe(codec: 'dvh1', codecs: 'dvh1.08.06', frameRate: 30)),
      'Dolby Vision Profile 8 (dvh1.08.06)  •  30 fps',
    );
    expect(videoCodecSummary(const SphericalProbe(codec: 'vp09', frameRate: 60)), 'VP9  •  60 fps');
  });
}
