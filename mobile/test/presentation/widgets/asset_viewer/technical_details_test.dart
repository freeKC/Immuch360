import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
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
    ));

    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('HEVC (hvc1.1.6.L183)  •  7680 x 3840  •  29.97 fps'), findsOneWidget);
    expect(find.text('Decodes on this device'), findsOneWidget);
    expect(find.text('Yes  •  Hardware  •  Up to 8192 x 4320'), findsOneWidget);
  });

  testWidgets('tells that the device does not decode a video, and its largest frame', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (
      probe: probe,
      verdict: DecodeVerdict(supported: false, hardware: true, maxWidth: 4096, maxHeight: 4096),
    ));

    expect(find.text('No  •  Up to 4096 x 4096'), findsOneWidget);
  });

  testWidgets('shows the codec alone when the decoder check gave nothing', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (probe: probe, verdict: null));

    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Decodes on this device'), findsNothing);
  });

  testWidgets('shows nothing of a video whose file could not be read', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    await pumpDetails(tester, video, (probe: null, verdict: null));

    expect(find.text('Codec'), findsNothing);
  });

  testWidgets('shows nothing of the kind for a photo', (tester) async {
    final photo = RemoteAssetFactory.create();
    await pumpDetails(tester, photo, (probe: probe, verdict: null));

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
      'AV1 (av01.0.13M.10)  •  3840 x 2160',
    );
    expect(videoCodecSummary(const SphericalProbe(codec: 'vp09', frameRate: 60)), 'VP9  •  60 fps');
  });
}
