import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';

/// The gaussianSplat request of lot S5 against its contract, which GaussianSplatSpecTest.kt reads too
void main() {
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/gaussian_splat_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;

  const cactus = GaussianSplatRequest(
    format: 'spz',
    formatVersion: 3,
    gaussians: 452451,
    shDegree: 0,
    fileBytes: 6824362,
    maxGaussians: 50000,
    name: 'gsplat-cactus.spz',
  );

  test('writes the JSON of the contract', () {
    expect(jsonDecode(cactus.toJsonString()), contract['gaussianSplat']);
    expect(jsonDecode(const StereoPhotoRequest.splat(cactus).toImmersiveJson()), contract['gaussianSplat']);
    final ply = GaussianSplatRequest.fromJson(contract['ply'])!;
    expect(ply.tool, 'make_splat_fixtures.py');
    expect(jsonDecode(ply.toJsonString()), contract['ply']);
  });

  test('reads back what it writes', () {
    expect(GaussianSplatRequest.fromJson(contract['gaussianSplat']), cactus);
  });

  test('reads nothing of what a reader of version 1 refuses', () {
    for (final request in contract['unknown'] as List) {
      expect(GaussianSplatRequest.fromJson(request), isNull, reason: jsonEncode(request));
    }
    expect(GaussianSplatRequest.fromJson(null), isNull);
  });
}
