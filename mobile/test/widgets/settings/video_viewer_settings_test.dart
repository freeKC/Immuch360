import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/video_viewer_settings.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final spatialSwitch = find.widgetWithText(SwitchListTile, 'Spatial 2.5D (experimental)');

  testWidgets('offers the Spatial 2.5D player on a phone, off by default', (tester) async {
    await tester.pumpTestWidget(
      context,
      const VideoViewerSettings(),
      overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
    );

    expect(spatialSwitch, findsOneWidget);
    expect(
      find.text(
        'Stereoscopic videos gain depth on a flat screen: the view follows your head, tracked with the front camera on '
        'the device only',
      ),
      findsOneWidget,
    );
    // On by default: the camera is still only used once the player is open
    expect(tester.widget<SwitchListTile>(spatialSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isTrue);
  });

  testWidgets('turns the Spatial 2.5D player on and off', (tester) async {
    await tester.pumpTestWidget(
      context,
      const VideoViewerSettings(),
      overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
    );

    await tester.tap(spatialSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isFalse);

    await tester.tap(spatialSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isTrue);
  });

  testWidgets('leaves the Spatial 2.5D player out on a Meta Quest', (tester) async {
    await tester.pumpTestWidget(
      context,
      const VideoViewerSettings(),
      overrides: [isHorizonOsProvider.overrideWith((ref) => true)],
    );

    expect(spatialSwitch, findsNothing);
    expect(find.byType(SwitchListTile), findsNWidgets(3), reason: 'the other video settings stay');
  });
}
