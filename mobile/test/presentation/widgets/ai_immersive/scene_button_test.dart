// The 3D scene buttons of the 2D panel of the Quest (design-final 2026-10-27, sections 3.5 and 9.2): offered with the
// request of the packet, or greyed with the reason the gate of this headset reads in the packet.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/scene_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  final sample = File('test/fixtures/ai_immersive/xmp_v1_scene_sample.xmp').readAsStringSync();
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final designRequest = ((contract['volumetricScene'] as List).first as Map<String, dynamic>)['request'];

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  SceneXmp sampleWith([Map<String, String> fields = const {}]) {
    var text = sample;
    fields.forEach(
      (name, value) => text = text.replaceFirst(RegExp('Immuch360:$name="[^"]*"'), 'Immuch360:$name="$value"'),
    );
    return ImmersiveXmp.parse(text)! as SceneXmp;
  }

  /// The button for [xmp] on the headset [device], recording what it asks the viewer to open
  Future<List<StereoPhotoRequest>> pumpButton(
    WidgetTester tester,
    SceneXmp xmp, {
    String device = 'eureka',
    bool fromOriginal = false,
    int? fileSize,
  }) async {
    final opened = <StereoPhotoRequest>[];
    // A fresh ProviderScope for each button of a test
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpTestWidget(
      context,
      AiSceneButton(
        xmp: xmp,
        fromOriginal: fromOriginal,
        fileSize: fileSize,
        open: (request) async => opened.add(request),
      ),
      overrides: [
        reliefDeviceFactsProvider.overrideWith((ref) async => ReliefDeviceFacts(device: device, memoryMiB: 7600)),
      ],
    );
    return opened;
  }

  IconButton button(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key));

  testWidgets('"Explore the 3D scene" opens the photo with the request of its packet, the JSON of the contract', (
    tester,
  ) async {
    final opened = await pumpButton(tester, sampleWith());

    expect(find.byTooltip('Explore the 3D scene'), findsOneWidget);
    await tester.tap(find.byKey(exploreSceneButtonKey));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(jsonDecode(opened.single.toImmersiveJson()), designRequest);
  });

  testWidgets('"View the 3D scene" on the original opens its scene the same way', (tester) async {
    final opened = await pumpButton(tester, sampleWith(), fromOriginal: true);

    expect(find.byTooltip('View the 3D scene'), findsOneWidget);
    expect(find.byKey(exploreSceneButtonKey), findsNothing);
    await tester.tap(find.byKey(viewSceneButtonKey));
    await tester.pump();
    expect(jsonDecode(opened.single.toImmersiveJson()), designRequest);
  });

  testWidgets('a scene too heavy for this headset keeps its button, greyed with the numbers', (tester) async {
    final opened = await pumpButton(tester, sampleWith({'SceneTriangles': '250000'}), device: 'hollywood');

    expect(button(tester, exploreSceneButtonKey).onPressed, isNull);
    expect(find.byTooltip('This scene is too heavy for this headset (250000 triangles, at most 200000)'), findsOneWidget);
    await tester.tap(find.byKey(exploreSceneButtonKey));
    expect(opened, isEmpty);
  });

  testWidgets('the same scene opens on a Quest 3', (tester) async {
    await pumpButton(tester, sampleWith({'SceneTriangles': '250000'}));

    expect(button(tester, exploreSceneButtonKey).onPressed, isNotNull);
  });

  testWidgets('a scene of a newer version, of another format, without its request or too large: greyed, each its reason', (
    tester,
  ) async {
    await pumpButton(tester, sampleWith({'FormatVersion': '2'}));
    expect(find.byTooltip('Made by a newer version of Immuch360: shown flat'), findsOneWidget);
    expect(button(tester, exploreSceneButtonKey).onPressed, isNull);

    await pumpButton(tester, sampleWith({'SceneFormat': 'splat-v1'}));
    expect(find.byTooltip('Not a scene made by Immuch360'), findsOneWidget);

    await pumpButton(tester, sampleWith({'SceneLength': ''}));
    expect(find.byTooltip('The 3D scene data is missing from this file'), findsOneWidget);

    await pumpButton(tester, sampleWith(), fileSize: 65 * 1024 * 1024);
    expect(find.byTooltip('This scene is too heavy for this headset'), findsOneWidget);
    expect(button(tester, exploreSceneButtonKey).onPressed, isNull);
  });
}
