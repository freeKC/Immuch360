import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/video_decoders.page.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  testWidgets('opens the video decoders of the device from the troubleshooting settings', (tester) async {
    await tester.pumpTestWidget(
      context,
      const AdvancedSettings(),
      overrides: [
        videoDecodersProvider.overrideWith(
          (ref) async => [
            DecoderInfo(
              name: 'c2.qti.hevc.decoder',
              codec: 'video/hevc',
              hardware: true,
              maxWidth: 8192,
              maxHeight: 4320,
              maxFrameRate: 30,
            ),
          ],
        ),
      ],
    );

    final entry = find.text('Video decoders of this device');
    expect(entry, findsOneWidget);
    expect(
      find.text('What this device decodes, by codec and size, to understand why a 360° video stutters'),
      findsOneWidget,
    );

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(VideoDecodersPage), findsOneWidget);
    expect(find.text('c2.qti.hevc.decoder'), findsOneWidget);
  });
}
