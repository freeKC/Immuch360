// The labels a photo of the stereo quad opens with: those of every opening, and the three of the flat 3D photos.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';

void main() {
  test('the flat 3D photos get their own labels, under the keys of the viewer', () {
    final labels = aiImmersiveViewerLabels(StaticTranslations.instance);

    expect(labels.keys, {'ai2dOriginal', 'aiReliefEstimated', 'aiNoNavigation'});
    expect(labels.values, everyElement(isNotEmpty));
  });

  test('a photo of the stereo quad opens with the labels of every opening and those of the flat 3D photos', () {
    final labels = stereoPhotoViewerLabels(StaticTranslations.instance);

    expect(labels.keys, containsAll(sphereViewerLabels(StaticTranslations.instance).keys));
    expect(labels.keys, containsAll(['ai2dOriginal', 'aiReliefEstimated', 'aiNoNavigation']));
  });
}
