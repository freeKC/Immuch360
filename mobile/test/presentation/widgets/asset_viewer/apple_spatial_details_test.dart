import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
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

  const pair = HeicStereoPair(
    primaryItemId: 37,
    leftItemId: 37,
    rightItemId: 74,
    pitmIdOffset: 129,
    pitmIdBytes: 2,
    width: 3072,
    height: 3072,
    disparityAdjustment: -1000,
    horizontalFovDegrees: 59.98,
  );
  final row = find.byKey(const Key('apple_spatial_details'));

  testWidgets('a spatial photo gets a row with the size of its two views and its field of view', (tester) async {
    final photo = RemoteAssetFactory.create(name: 'IMG_0001.HEIC');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: photo),
      overrides: [appleSpatialInfoProvider(photo).overrideWith((ref) async => const AppleSpatialInfo.photo(pair))],
    );

    expect(row, findsOneWidget);
    expect(find.text('Apple spatial photo, two views of 3072 x 3072'), findsOneWidget);
    expect(find.text('field of view 60°'), findsOneWidget);
  });

  testWidgets('a HEIF photo without a pair gets no row', (tester) async {
    final photo = RemoteAssetFactory.create(name: 'IMG_0002.HEIC');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: photo),
      overrides: [appleSpatialInfoProvider(photo).overrideWith((ref) async => null)],
    );

    expect(row, findsNothing);
  });

  testWidgets('a photo under another name is not read for a pair', (tester) async {
    final photo = RemoteAssetFactory.create(name: 'IMG_0003.jpg');
    var read = false;
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: photo),
      overrides: [
        appleSpatialInfoProvider(photo).overrideWith((ref) async {
          read = true;
          return const AppleSpatialInfo.photo(pair);
        }),
      ],
    );

    expect(row, findsNothing);
    expect(read, isFalse);
  });

  testWidgets('a spatial video gets a row with the eye shown, the baseline and the field of view', (tester) async {
    final video = RemoteAssetFactory.create(type: .video, name: 'IMG_0100.MOV');
    const probe = SphericalProbe(
      codec: 'hvc1',
      codecs: 'hvc1.2.4.L153',
      codedWidth: 1920,
      codedHeight: 1080,
      multiview: MultiviewInfo(heroEye: 1, baselineMicrometres: 19240, horizontalFovDegrees: 63.4),
    );
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: video),
      overrides: [
        videoDecodeDetailsProvider(video).overrideWith((ref) async => (probe: probe, verdict: null, bitRate: null)),
      ],
    );

    expect(row, findsOneWidget);
    expect(find.text('Apple spatial video (MV-HEVC), shown in 2D'), findsOneWidget);
    expect(find.text('left eye, baseline 19.2 mm, field of view 63°'), findsOneWidget);
  });

  testWidgets('a spatial video that tells nothing more gets the row alone', (tester) async {
    final video = RemoteAssetFactory.create(type: .video, name: 'IMG_0101.MOV');
    const probe = SphericalProbe(codec: 'hvc1', multiview: MultiviewInfo(heroEye: 0));
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: video),
      overrides: [
        videoDecodeDetailsProvider(video).overrideWith((ref) async => (probe: probe, verdict: null, bitRate: null)),
      ],
    );

    expect(find.text('Apple spatial video (MV-HEVC), shown in 2D'), findsOneWidget);
  });

  testWidgets('a plain video gets no row', (tester) async {
    final video = RemoteAssetFactory.create(type: .video);
    const probe = SphericalProbe(codec: 'hvc1');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: video),
      overrides: [
        videoDecodeDetailsProvider(video).overrideWith((ref) async => (probe: probe, verdict: null, bitRate: null)),
      ],
    );

    expect(row, findsNothing);
  });

  test('the millimetres of a baseline', () {
    expect(formatMillimetres(64000), '64');
    expect(formatMillimetres(19240), '19.2');
  });
}
