import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';

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

  const notice = 'Spatial video: this device plays one eye';
  const spatialProbe = SphericalProbe(codec: 'hvc1', multiview: MultiviewInfo(heroEye: 1));

  /// The service of the spatial media, the probe of each video by its name, without a store
  AppleSpatialService service(Map<String, SphericalProbe?> probes) => AppleSpatialService(
    localFile: (_) async => null,
    serverReader: (_) => null,
    probeVideo: (asset) async => probes[asset.name],
    readCache: () => null,
    writeCache: (_) async {},
  );

  /// The context of a viewer on screen
  Future<BuildContext> pumpViewer(WidgetTester tester) async {
    late BuildContext viewerContext;
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) {
          viewerContext = context;
          return const SizedBox();
        },
      ),
    );
    return viewerContext;
  }

  testWidgets('a spatial video tells once in the session that it plays one eye', (tester) async {
    final viewer = await pumpViewer(tester);
    final video = RemoteAssetFactory.create(type: AssetType.video, name: 'IMG_0100.MOV');
    final spatial = service({'IMG_0100.MOV': spatialProbe});

    expect(await noticeAppleSpatialVideo(viewer, spatial, video), isTrue);
    await tester.pump();
    expect(find.text(notice), findsOneWidget);

    expect(await noticeAppleSpatialVideo(viewer, spatial, video), isFalse, reason: 'once per video');
  });

  testWidgets('each spatial video tells it the first time it plays', (tester) async {
    final viewer = await pumpViewer(tester);
    final first = RemoteAssetFactory.create(type: AssetType.video, name: 'IMG_0100.MOV');
    final second = RemoteAssetFactory.create(type: AssetType.video, name: 'IMG_0101.MOV');
    final spatial = service({'IMG_0100.MOV': spatialProbe, 'IMG_0101.MOV': spatialProbe});

    expect(await noticeAppleSpatialVideo(viewer, spatial, first), isTrue);
    expect(await noticeAppleSpatialVideo(viewer, spatial, second), isTrue);
  });

  testWidgets('a plain video, and one whose file could not be read, tell nothing', (tester) async {
    final viewer = await pumpViewer(tester);
    final plain = RemoteAssetFactory.create(type: AssetType.video, name: 'plain.mp4');
    final unread = RemoteAssetFactory.create(type: AssetType.video, name: 'unread.mp4');
    final spatial = service({'plain.mp4': const SphericalProbe(codec: 'hvc1')});

    expect(await noticeAppleSpatialVideo(viewer, spatial, plain), isFalse);
    expect(await noticeAppleSpatialVideo(viewer, spatial, unread), isFalse);
    await tester.pump();
    expect(find.text(notice), findsNothing);
  });
}
