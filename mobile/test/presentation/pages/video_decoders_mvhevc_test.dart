import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/video_decoders.page.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final hevc = DecoderInfo(
    name: 'c2.qti.hevc.decoder',
    codec: 'video/hevc',
    hardware: true,
    maxWidth: 8192,
    maxHeight: 4320,
    maxFrameRate: 30,
  );
  final noneRow = find.byKey(const Key('video_decoders_mvhevc_none'));

  Future<void> pumpPage(WidgetTester tester, List<DecoderInfo> decoders) => tester.pumpTestWidget(
    context,
    const VideoDecodersPage(),
    overrides: [videoDecodersProvider.overrideWith((ref) async => decoders)],
  );

  testWidgets('says when the device has no MV-HEVC decoder, the spatial videos then playing one eye', (tester) async {
    await pumpPage(tester, [hevc]);

    expect(find.text('MV-HEVC  •  video/x-mvhevc'), findsOneWidget);
    expect(noneRow, findsOneWidget);
    expect(find.descendant(of: noneRow, matching: find.text('None')), findsOneWidget);
    expect(find.text('Spatial video: this device plays one eye'), findsOneWidget);
  });

  testWidgets('lists the MV-HEVC decoder of the device under its name', (tester) async {
    await pumpPage(tester, [
      hevc,
      DecoderInfo(
        name: 'c2.qti.mvhevc.decoder',
        codec: mvHevcDecoderMimeType,
        hardware: true,
        maxWidth: 4096,
        maxHeight: 4096,
        maxFrameRate: 30,
      ),
    ]);

    expect(find.text('MV-HEVC  •  video/x-mvhevc'), findsOneWidget);
    expect(find.text('c2.qti.mvhevc.decoder'), findsOneWidget);
    expect(noneRow, findsNothing);
    expect(
      videoDecodersReport([
        DecoderInfo(
          name: 'c2.qti.mvhevc.decoder',
          codec: mvHevcDecoderMimeType,
          hardware: true,
          maxWidth: 4096,
          maxHeight: 4096,
          maxFrameRate: 0,
        ),
      ]),
      'Video decoders\nMV-HEVC (video/x-mvhevc)\n  c2.qti.mvhevc.decoder: hardware, up to 4096 x 4096',
    );
  });
}
