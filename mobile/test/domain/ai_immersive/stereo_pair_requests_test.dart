import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';

void main() {
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  Map<String, dynamic> request(String kind, int index) =>
      ((contract[kind] as List)[index] as Map<String, dynamic>)['request'] as Map<String, dynamic>;
  final cacheKeys = (contract['cacheKeys'] as List).cast<Map<String, dynamic>>();

  group('sbsPhoto', () {
    test('our file writes the JSON of the contract', () {
      const ours = SbsPhotoRequest(origin: ImmersiveOrigin.estimatedDepth, leftEye: LeftEyeSource.original);

      expect(jsonDecode(ours.toJsonString()), request('sbsPhoto', 0));
    });

    test('a file of another tool, eyes swapped and half width, writes the JSON of the contract', () {
      const other = SbsPhotoRequest(layout: EyeOrder.rightLeft, eyes: StereoEyes.half);

      expect(jsonDecode(other.toJsonString()), request('sbsPhoto', 1));
    });

    test('reads back what it writes', () {
      for (var i = 0; i < 2; i++) {
        final read = SbsPhotoRequest.fromJson(request('sbsPhoto', i));

        expect(read, isNotNull);
        expect(read!.toJson(), request('sbsPhoto', i));
      }
    });
  });

  group('depthRelief', () {
    const model =
        '/data/user/0/com.aprogsys.immuch360/files/ai-components/models/depth-anything-v2-small/'
        'depth_anything_v2_small.tflite';

    test('a photo of the server writes the JSON of the contract', () {
      final relief = DepthReliefRequest(
        model: model,
        modelSize: 99530468,
        modelId: depthModelId(depthModelTfliteSha256),
        cacheKey: reliefCacheKey(
          identity: ReliefSourceIdentity.sha1('X8tYgvibyzHDDN2yXGU/ft1XxeM='),
          modelId: depthModelId(depthModelTfliteSha256),
        ),
      );

      expect(jsonDecode(relief.toJsonString()), request('depthRelief', 0));
    });

    test('a photo of a share turned once writes the JSON of the contract', () {
      final share = cacheKeys[1]['share'] as Map<String, dynamic>;
      final identity = ReliefSourceIdentity.share(
        source: share['source'] as String,
        path: share['path'] as String,
        size: share['size'] as int,
        modified: DateTime.fromMillisecondsSinceEpoch(share['modifiedMs'] as int, isUtc: true),
      );
      final modelId = depthModelId(depthModelTfliteSha256);
      final relief = DepthReliefRequest(
        model: model,
        modelSize: 99530468,
        modelId: modelId,
        cacheKey: reliefCacheKey(identity: identity, modelId: modelId, quarterTurns: 1),
        quarterTurns: 1,
      );

      expect(jsonDecode(relief.toJsonString()), request('depthRelief', 1));
    });

    test('a photo of the server first shown in 2.5D writes the JSON of the contract', () {
      final relief = DepthReliefRequest(
        model: model,
        modelSize: 99530468,
        modelId: depthModelId(depthModelTfliteSha256),
        cacheKey: reliefCacheKey(
          identity: ReliefSourceIdentity.sha1('X8tYgvibyzHDDN2yXGU/ft1XxeM='),
          modelId: depthModelId(depthModelTfliteSha256),
        ),
        mode: ReliefViewMode.mesh25d,
      );

      expect(jsonDecode(relief.toJsonString()), request('depthRelief', 2));
      // The same photo and the same map as in stereo: only the first view changes
      expect(relief.cacheKey, request('depthRelief', 0)['cacheKey']);
    });

    test('reads back what it writes', () {
      for (var i = 0; i < 3; i++) {
        expect(DepthReliefRequest.fromJson(request('depthRelief', i))!.toJson(), request('depthRelief', i));
      }
      expect(DepthReliefRequest.fromJson(request('depthRelief', 2))!.mode, ReliefViewMode.mesh25d);
    });

    test('a request without a mode, or with a mode this build does not know, first shows in stereo', () {
      expect(DepthReliefRequest.fromJson(request('depthRelief', 0))!.mode, ReliefViewMode.stereo);
      for (final mode in ['volumetric', 'stereo', 2, null]) {
        final json = {...request('depthRelief', 2), 'mode': mode};

        expect(DepthReliefRequest.fromJson(json)!.mode, ReliefViewMode.stereo, reason: '$mode');
      }
      // A stereo request does not name its mode: the JSON of every request before 2.5D
      expect(DepthReliefRequest.fromJson(request('depthRelief', 0))!.toJson().containsKey('mode'), isFalse);
    });
  });

  group('volumetricScene', () {
    const designSha256 = '3040c8c4f61d1a2a5b7cc6485a952bbb1ad346d70e76a7332b285f7f8de41d1d';

    test('the scene of the design writes the JSON of the contract', () {
      const scene = VolumetricSceneRequest(
        sceneLength: 6712344,
        sceneSha256: designSha256,
        meshes: 2,
        vertices: 58210,
        triangles: 113877,
        textureMax: 4096,
        safe: SceneSafeZone(lateral: 0.22, vertical: 0.13, forward: 0.48, backward: 0.11),
        fovDegrees: 65.4,
        flags: [ReliefQualityFlag.hiddenAreas],
      );

      expect(jsonDecode(scene.toJsonString()), request('volumetricScene', 0));
      expect(scene.origin, ImmersiveOrigin.reconstructedFromPhoto);
      expect(scene.format, glbLayersV1);
    });

    test('a close photo scaled for comfort, without flags, writes the JSON of the contract', () {
      final close = request('volumetricScene', 1);
      final scene = VolumetricSceneRequest(
        sceneLength: 412,
        sceneSha256: close['sceneSha256'] as String,
        meshes: 1,
        vertices: 9,
        triangles: 8,
        textureMax: 64,
        scale: 1.6,
        safe: const SceneSafeZone(lateral: 0.1, vertical: 0.06, forward: 0.1, backward: 0.05),
        fovDegrees: 50,
      );

      expect(jsonDecode(scene.toJsonString()), close);
    });

    test('reads back what it writes', () {
      for (var i = 0; i < 2; i++) {
        final read = VolumetricSceneRequest.fromJson(request('volumetricScene', i));

        expect(read, isNotNull);
        expect(read!.toJson(), request('volumetricScene', i));
      }
    });

    test('the flags are written in the order of the XMP, a later origin or flag reads as unknown', () {
      final json = {
        ...request('volumetricScene', 0),
        'origin': 'fromSeveralPhotos',
        'flags': ['sparkles', 'dark', 'hiddenAreas'],
      };
      final read = VolumetricSceneRequest.fromJson(json)!;

      expect(read.origin, ImmersiveOrigin.unknown);
      expect(read.flags, [ReliefQualityFlag.hiddenAreas, ReliefQualityFlag.dark]);
      expect(read.toJson()['flags'], ['hiddenAreas', 'dark']);
    });

    test('a request that cannot be right is none', () {
      final scene = request('volumetricScene', 0);
      for (final change in <Map<String, Object?>>[
        {'version': 2},
        {'format': 'glb-layers-v2'},
        {'format': null},
        {'sceneLength': 0},
        {'sceneLength': '6712344'},
        {'sceneSha256': designSha256.toUpperCase()},
        {'sceneSha256': '../scene'},
        {'meshes': 0},
        {'vertices': -1},
        {'triangles': 0},
        {'textureMax': 0},
        {'scale': 0},
        {'safe': null},
        {
          'safe': {'lateral': 0.22, 'vertical': 0.13, 'forward': 0.48},
        },
        {
          'safe': {'lateral': -0.22, 'vertical': 0.13, 'forward': 0.48, 'backward': 0.11},
        },
        {'fovDegrees': 180},
        {'fovDegrees': null},
        {'flags': 'hiddenAreas'},
      ]) {
        expect(VolumetricSceneRequest.fromJson({...scene, ...change}), isNull, reason: '$change');
      }
      // No flags at all is no flag
      expect(VolumetricSceneRequest.fromJson({...scene}..remove('flags'))!.flags, isEmpty);
    });
  });

  test('the requests a reader of version 1 refuses are refused', () {
    for (final unknown in (contract['unknown'] as List).cast<Map<String, dynamic>>()) {
      expect(SbsPhotoRequest.fromJson(unknown), isNull, reason: '$unknown');
      expect(DepthReliefRequest.fromJson(unknown), isNull, reason: '$unknown');
      expect(VolumetricSceneRequest.fromJson(unknown), isNull, reason: '$unknown');
    }
    // A 3D scene of version 1 is a request of this build, no longer an unknown one
    expect(
      (contract['unknown'] as List).cast<Map<String, dynamic>>().where(
        (unknown) => unknown['kind'] == volumetricSceneKind && unknown['version'] == volumetricSceneVersion,
      ),
      isEmpty,
    );
  });

  test('the keys of the labels of a generated panorama are those the immersive viewer reads', () {
    expect(generatedNoticeLabelKey, 'generatedNotice');
    expect(photoRegionLabelKey, 'photoRegion');
  });

  group('the relief cache key', () {
    test('is the SHA-256 of the text of the contract', () {
      for (final entry in cacheKeys) {
        final text = reliefCacheKeyText(
          identity: entry['identity'] as String,
          modelId: entry['modelId'] as String,
          pipeline: entry['pipeline'] as String,
          parallax: entry['parallax'] as double,
          convergence: entry['convergence'] as double,
          quarterTurns: entry['quarterTurns'] as int,
        );

        expect(text, entry['text']);
        expect(
          reliefCacheKey(
            identity: entry['identity'] as String,
            modelId: entry['modelId'] as String,
            quarterTurns: entry['quarterTurns'] as int,
          ),
          entry['key'],
        );
      }
    });

    test('is stable and changes with every field', () {
      const identity = 'sha1:X8tYgvibyzHDDN2yXGU/ft1XxeM=';
      const modelId = 'depth-anything-v2-small@651415f1';
      final key = reliefCacheKey(identity: identity, modelId: modelId);

      expect(reliefCacheKey(identity: identity, modelId: modelId), key);
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      final others = {
        reliefCacheKey(identity: 'sha1:other', modelId: modelId),
        reliefCacheKey(identity: identity, modelId: 'depth-anything-v2-small@afb6a5c2'),
        reliefCacheKey(identity: identity, modelId: modelId, pipeline: 'relief-v2'),
        reliefCacheKey(identity: identity, modelId: modelId, parallax: 0.03),
        reliefCacheKey(identity: identity, modelId: modelId, convergence: 0.4),
        reliefCacheKey(identity: identity, modelId: modelId, quarterTurns: 1),
      };

      expect(others, hasLength(6));
      expect(others, isNot(contains(key)));
      // Four quarter turns are none
      expect(reliefCacheKey(identity: identity, modelId: modelId, quarterTurns: 4), key);
    });

    test('a share identity names the source, the path, the size and the date in UTC milliseconds', () {
      final identity = ReliefSourceIdentity.share(
        source: 'nas',
        path: '/a/b.jpg',
        size: 10,
        modified: DateTime.utc(2026, 10, 27, 9, 12),
      );

      expect(identity, 'share:nas:/a/b.jpg:10:1793092320000');
      expect(ReliefSourceIdentity.sha1('abc='), 'sha1:abc=');
    });
  });

  test('the folder of the relief cache is the one the immersive viewer writes in', () {
    // ReliefCache.FOLDER of the Kotlin side, read from its source: both sides must name the same folder
    final kotlin = File('android/app/src/main/kotlin/app/alextran/immich/relief/ReliefCache.kt').readAsStringSync();

    expect(RegExp(r'const val FOLDER = "([^"]+)"').firstMatch(kotlin)?.group(1), reliefCacheFolderName);
    expect(reliefCacheFolderName, 'ai-relief');
  });

  test('the model id is the name and the first 8 digits of the SHA-256', () {
    expect(depthModelId(depthModelTfliteSha256), 'depth-anything-v2-small@651415f1');
    expect(depthModelId(depthModelOnnxSha256), 'depth-anything-v2-small@afb6a5c2');
  });
}
