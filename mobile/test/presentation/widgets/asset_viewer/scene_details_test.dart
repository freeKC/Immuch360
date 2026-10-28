// The row of a photo that carries a 3D scene in the details, on the phones, tablets and TVs (design-final 2026-10-27,
// section 9.3): what it is and where to explore it; nothing on the Quest, which has its button, nor for another photo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/scene_photo.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  final sample =
      ImmersiveXmp.parse(File('test/fixtures/ai_immersive/xmp_v1_scene_sample.xmp').readAsStringSync())! as SceneXmp;
  final row = find.byKey(const Key('ai_immersive_scene_details'));

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  testWidgets('a photo that carries a scene says what it is and to open it on a Meta Quest', (tester) async {
    final photo = RemoteAssetFactory.create(name: 'salon_scene3D.jpg');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: photo),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => false),
        scenePhotoProvider(photo).overrideWith((ref) async => sample),
      ],
    );

    expect(row, findsOneWidget);
    expect(find.text('3D scene, reconstructed from one photo'), findsOneWidget);
    expect(find.text('Open it on a Meta Quest to explore it'), findsOneWidget);
  });

  testWidgets('nothing on the Quest, which offers "Explore the 3D scene"', (tester) async {
    final photo = RemoteAssetFactory.create(name: 'salon_scene3D.jpg');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: photo),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => true),
        scenePhotoProvider(photo).overrideWith((ref) async => sample),
      ],
    );

    expect(row, findsNothing);
  });

  testWidgets('a photo named like a scene without one, and an ordinary photo, get no row; the latter is not read', (
    tester,
  ) async {
    final renamed = RemoteAssetFactory.create(name: 'holiday_scene3D.jpg');
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: renamed),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => false),
        scenePhotoProvider(renamed).overrideWith((ref) async => null),
      ],
    );
    expect(row, findsNothing);

    final ordinary = RemoteAssetFactory.create(name: 'salon.jpg');
    var read = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpTestWidget(
      context,
      TechnicalDetails(asset: ordinary),
      overrides: [
        isHorizonOsProvider.overrideWith((ref) async => false),
        scenePhotoProvider(ordinary).overrideWith((ref) async {
          read = true;
          return sample;
        }),
      ],
    );
    expect(row, findsNothing);
    expect(read, isFalse);
  });
}
