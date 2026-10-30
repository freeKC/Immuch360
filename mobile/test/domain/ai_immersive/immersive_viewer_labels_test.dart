// The labels a photo of the stereo quad opens with: those of every opening, and those of the flat 3D photos and of
// the relief the headset makes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The English texts, from a widget under the app's localisation
  Future<Translations> english(WidgetTester tester) async {
    late Translations t;
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox();
        },
      ),
    );
    return t;
  }

  test('the flat 3D photos get their own labels, under the keys of the viewer', () {
    final labels = aiImmersiveViewerLabels(StaticTranslations.instance);

    expect(labels.keys, {
      'ai2dOriginal',
      'ai25d',
      'aiReliefEstimated',
      'aiNoNavigation',
      'aiReliefPreparing',
      'aiReliefEstimating',
      'aiReliefBuilding',
      'aiReliefStop',
      'aiReliefTooWarm',
      'aiReliefFailed',
      'aiReliefNotInVersion',
      'aiReliefNoMemory',
      'aiReliefMissing',
      'aiReliefDamaged',
    });
    expect(labels.values, everyElement(isNotEmpty));
  });

  testWidgets('the relief the headset makes says its stages and why it left a photo flat', (tester) async {
    final labels = aiImmersiveViewerLabels(await english(tester));

    expect(labels['aiReliefPreparing'], 'Preparing');
    expect(labels['aiReliefEstimating'], 'Estimating the relief (AI)');
    expect(labels['aiReliefBuilding'], 'Building the right eye');
    expect(labels['aiReliefStop'], 'Stop relief');
    expect(labels['aiReliefTooWarm'], 'Headset too warm, relief stopped');
    expect(labels['aiReliefNotInVersion'], 'Not in this version of the app');
    expect(labels['aiReliefNoMemory'], 'Not enough memory');
    expect(labels['aiReliefMissing'], 'The AI components are not installed');
    expect(labels['aiReliefDamaged'], 'An AI component is damaged');
  });

  testWidgets('the 3D button names the 2.5D view of a relief, experimental', (tester) async {
    expect(aiImmersiveViewerLabels(await english(tester))['ai25d'], '2.5D (experimental)');
  });

  testWidgets('a failed relief keeps the place of its reason for the headset', (tester) async {
    // The viewer puts the message of the failure there (StereoComposer.reliefStopText)
    expect(aiImmersiveViewerLabels(await english(tester))['aiReliefFailed'], 'The relief failed: {reason}');
  });

  test('a photo of the stereo quad opens with the labels of every opening and those of the flat 3D photos', () {
    final labels = stereoPhotoViewerLabels(StaticTranslations.instance);

    expect(labels.keys, containsAll(sphereViewerLabels(StaticTranslations.instance).keys));
    expect(labels.keys, containsAll(['ai2dOriginal', 'aiReliefEstimated', 'aiNoNavigation']));
    expect(labels.keys, containsAll(sceneViewerLabels(StaticTranslations.instance).keys));
    expect(labels.keys, containsAll(flat3dViewerLabels(StaticTranslations.instance).keys));
  });

  testWidgets('a media told 3D by its file name says so, experimental, and that a video plays on its own', (
    tester,
  ) async {
    final labels = flat3dViewerLabels(await english(tester));

    expect(labels, {
      'flat3dNotice': '3D told by the file name (experimental)',
      'flat3dNoNavigation': 'A 3D video plays on its own: B or Y goes back to the app',
    });
  });

  test('a 3D scene gets its own labels, under the keys SceneTexts of the headset reads', () {
    final labels = sceneViewerLabels(StaticTranslations.instance);

    expect(labels.keys, {
      'sceneHonesty',
      'scenePreparing',
      'sceneEdge',
      'sceneReset',
      'scenePhoto2d',
      'scene3d',
      'sceneHint',
      'sceneZone',
      'sceneHidden',
      'sceneTooHeavy',
      'sceneTooHeavyPlain',
      'sceneNewer',
      'sceneNotOurs',
      'sceneNoMemory',
      'sceneTooWarm',
      'sceneMissing',
      'sceneFailed',
      'sceneFlag_lowRelief',
      'sceneFlag_hiddenAreas',
      'sceneFlag_dark',
      'sceneFlag_sky',
      'sceneFlag_fovGuessed',
      'sceneFlag_smallZone',
    });
    expect(labels.values, everyElement(isNotEmpty));
  });

  testWidgets('the words of a scene in English, the places of their numbers kept for the headset', (tester) async {
    final labels = sceneViewerLabels(await english(tester));

    // The English texts of SceneTexts.englishLabels in SceneView.kt
    expect(labels['sceneHonesty'], 'Reconstructed from one photo, explore within its limits');
    expect(labels['scenePreparing'], 'Preparing the 3D scene');
    expect(labels['sceneEdge'], 'Edge of the reconstructed area. Reset is in the panel.');
    expect(labels['sceneReset'], 'Reset');
    expect(labels['scenePhoto2d'], 'Photo (2D)');
    expect(labels['scene3d'], '3D scene');
    expect(
      labels['sceneHint'],
      'Left thumbstick: glide. Click a thumbstick: Reset. A, X or grip: show or hide this panel. B or Y: back to the '
      'app.',
    );
    expect(labels['sceneZone'], 'Room to move: about {size} each way');
    expect(labels['sceneHidden'], 'Hidden areas filled: {percent}%');
    expect(labels['sceneTooHeavy'], 'This scene is too heavy for this headset ({triangles} triangles, at most {max})');
    expect(labels['sceneTooHeavyPlain'], 'This scene is too heavy for this headset');
    expect(labels['sceneNewer'], 'Made by a newer version of Immuch360: shown flat');
    expect(labels['sceneNotOurs'], 'Not a scene made by Immuch360');
    expect(labels['sceneNoMemory'], 'Not enough free memory');
    expect(labels['sceneTooWarm'], 'Headset too warm');
    expect(labels['sceneMissing'], 'The 3D scene data is missing from this file');
    expect(labels['sceneFailed'], 'The 3D scene could not be shown: {reason}');
    expect(labels['sceneFlag_fovGuessed'], 'Field of view guessed: shapes may be off');
  });
}
