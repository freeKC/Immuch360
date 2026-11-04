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

  group('the scene of a splat photo (plan of 3 November 2026, lot L4)', () {
    const room = GaussianSplatRequest(
      format: 'spz',
      formatVersion: 2,
      gaussians: 150000,
      shDegree: 3,
      fileBytes: 3612448,
      maxGaussians: 50000,
      name: 'mipnerf360-room-brush-150k.spz',
      up: 'yUp',
    );

    test('writes the request of version 1 with its up, the request of the contract', () {
      expect(jsonDecode(room.toJsonString()), contract['splatPhoto']);
      expect(GaussianSplatRequest.fromJson(contract['splatPhoto']), room);
    });

    test('a request without up is written as before: no up key', () {
      expect((jsonDecode(cactus.toJsonString()) as Map).containsKey('up'), isFalse);
    });

    test('an up this build does not know is no up, the request still read', () {
      for (final value in ['sideways', 1, null]) {
        final read = GaussianSplatRequest.fromJson({...contract['splatPhoto'] as Map<String, dynamic>, 'up': value});
        expect(read, isNotNull, reason: '$value');
        expect(read!.up, isNull);
      }
    });
  });
}
