// The JSON of an Apple spatial photo reaches the immersive viewer of the Meta Quest, whether the media opens the viewer
// or replaces the one shown for previous and next; any other media sends none.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';

class _RecordingImmersiveApi extends ImmersiveApi {
  /// The stereoPair given with each media opened, null for none
  final opened = <String?>[];

  /// The stereoPair given with each media shown in place, null for none
  final shown = <String?>[];

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
  ) async => opened.add(stereoPair);

  @override
  Future<bool> showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
  ) async {
    shown.add(stereoPair);
    return true;
  }
}

const _flat = (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full);

// The values of the sample of the design (section 5.6): the left eye is the primary item
final _pair = jsonEncode({
  'kind': 'heicStereoPair',
  'version': 1,
  'primaryItemId': 37,
  'leftItemId': 37,
  'rightItemId': 74,
  'pitmIdOffset': 129,
  'pitmIdBytes': 2,
  'width': 3072,
  'height': 3072,
  'rotation': 0,
});

void main() {
  late _RecordingImmersiveApi api;

  setUp(() => api = _RecordingImmersiveApi());

  test('a request carries no stereo pair unless given one', () {
    const request = ImmersiveRequest(url: 'file:///photo.jpg', isVideo: false, title: 'photo.jpg', view: _flat);

    expect(request.stereoPair, isNull);
  });

  test('open hands the stereo pair of a spatial photo to the viewer', () async {
    final request = ImmersiveRequest(
      url: 'file:///IMG_0001.HEIC',
      isVideo: false,
      title: 'IMG_0001.HEIC',
      view: _flat,
      stereoPair: _pair,
    );

    await openImmersiveRequest(api, request, stereoLabels: const {}, openingId: 1);

    expect(api.opened, [_pair]);
  });

  test('showAdjacent hands the stereo pair over too, and null for any other media', () async {
    final spatial = ImmersiveRequest(
      url: 'file:///IMG_0001.HEIC',
      isVideo: false,
      title: 'IMG_0001.HEIC',
      view: _flat,
      stereoPair: _pair,
    );
    const sphere = ImmersiveRequest(url: 'file:///pano.jpg', isVideo: false, title: 'pano.jpg', view: _flat);

    expect(await showImmersiveRequest(api, 7, spatial), isTrue);
    expect(await showImmersiveRequest(api, 8, sphere), isTrue);

    expect(api.shown, [_pair, null]);
  });
}
