// The labels a photo of the stereo quad opens with: those of every opening, and those of the flat 3D photos and of
// the relief the headset makes.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';

void main() {
  test('the flat 3D photos get their own labels, under the keys of the viewer', () {
    final labels = aiImmersiveViewerLabels(StaticTranslations.instance);

    expect(labels.keys, {
      'ai2dOriginal',
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

  test('the relief the headset makes says its stages and why it left a photo flat, in English by default', () {
    final labels = aiImmersiveViewerLabels(StaticTranslations.instance);

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

  test('a failed relief keeps the place of its reason for the headset', () {
    // The viewer puts the message of the failure there (StereoComposer.reliefStopText)
    expect(aiImmersiveViewerLabels(StaticTranslations.instance)['aiReliefFailed'], 'The relief failed: {reason}');
  });

  test('a photo of the stereo quad opens with the labels of every opening and those of the flat 3D photos', () {
    final labels = stereoPhotoViewerLabels(StaticTranslations.instance);

    expect(labels.keys, containsAll(sphereViewerLabels(StaticTranslations.instance).keys));
    expect(labels.keys, containsAll(['ai2dOriginal', 'aiReliefEstimated', 'aiNoNavigation']));
  });
}
