import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

const _fixtures = 'test/fixtures/ai_immersive';

String _fixture(String name) => File('$_fixtures/$name').readAsStringSync();

// The sums of the samples, as make_scene_fixture.py makes them: the real ones come with the catalogue
String _sha256Of(String text) => sha256.convert(utf8.encode(text)).toString();

void main() {
  const salon = (name: 'salon.jpg', size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=');
  const created = '2026-10-27T10:12:00+01:00';
  const tool = 'Immuch360 Desktop 3.4.0 (windows)';
  const region = PhotoRegion(yaw: 0, pitch: 0, hfov: 65.4, vfov: 50.6);

  // The scene of the sample, from a 4:3 photo; [width] x [height] is the size of its map
  SceneXmp scene({int width = 1024, int height = 768}) => SceneXmp.reconstructed(
    sceneLength: 6712344,
    sceneSha256: _sha256Of('glb-layers-v1 sample of the stereoPair contract'),
    sceneMeshes: 2,
    sceneVertices: 58210,
    sceneTriangles: 113877,
    sceneTextureMax: 4096,
    sceneScale: 1.0,
    gridStep: SceneV1.gridStepFor(width, height),
    safe: const SceneSafeZone(lateral: 0.22, vertical: 0.13, forward: 0.48, backward: 0.11),
    fieldOfView: 65.4,
    fieldOfViewSource: FieldOfViewSource.exif,
    geometryModel: 'moge-2-vits-normal-onnx-immuch360',
    geometryModelSha256: _sha256Of('sample of moge-2-vits-normal-onnx-immuch360'),
    inpaintModel: 'lama-onnx',
    inpaintModelSha256: _sha256Of('sample of lama-onnx'),
    hiddenFraction: 0.07,
    sourceName: salon.name,
    sourceSize: salon.size,
    sourceSha1: salon.sha1,
    sourceQuarterTurns: 0,
    created: created,
    creatorTool: tool,
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000001',
    qualityFlags: const [ReliefQualityFlag.hiddenAreas],
  );

  PanoramaXmp panorama() => PanoramaXmp.generated(
    width: 8192,
    height: 4096,
    region: region,
    sourceCoverage: 0.08,
    generator: 'flux2-klein-base-4b-q8_0',
    generatorSha256: _sha256Of('sample of flux2-klein-base-4b-q8_0'),
    generatorLora: 'flux2-klein-4b-360-erp-lora-v1',
    generatorLoraSha256: _sha256Of('sample of flux2-klein-4b-360-erp-lora-v1'),
    seed: 1234567890,
    steps: 28,
    upscaler: 'realesrgan-x4plus',
    sourceName: salon.name,
    sourceSize: salon.size,
    sourceSha1: salon.sha1,
    sourceQuarterTurns: 0,
    created: created,
    creatorTool: tool,
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000002',
    qualityFlags: const [ReliefQualityFlag.fovGuessed],
  );

  StereoPanoramaXmp stereoPanorama() => StereoPanoramaXmp.estimated(
    width: 4096,
    height: 4096,
    depthModelSha256: depthModelOnnxSha256,
    sourceName: salon.name,
    sourceSize: salon.size,
    sourceSha1: salon.sha1,
    sourceQuarterTurns: 0,
    created: created,
    creatorTool: tool,
    parent: panorama(),
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000003',
  );

  group('the packets of the samples', () {
    test('a scene writes xmp_v1_scene_sample.xmp byte for byte, and reads it back', () {
      final fixture = _fixture('xmp_v1_scene_sample.xmp');

      expect(scene().toXml(), fixture);
      expect(SceneXmp.parse(fixture), scene());
      expect(ImmersiveXmp.parse(fixture), isA<SceneXmp>());
      // SourceSha1 ends with =: written as an entity, read back as the character
      expect(fixture, contains('Immuch360:SourceSha1="X8tYgvibyzHDDN2yXGU/ft1XxeM&#x3D;"'));
      expect(fixture, contains('Iptc4xmpExt:DigitalSourceType="$iptcCompositeWithTrainedAlgorithmicMedia"'));
      expect(SceneXmp.parse(fixture)!.description, contains(sceneHonesty));
    });

    test('a panorama writes xmp_v1_panorama_sample.xmp byte for byte, with its GPano tags as they are', () {
      final fixture = _fixture('xmp_v1_panorama_sample.xmp');

      expect(panorama().toXml(), fixture);
      expect(PanoramaXmp.parse(fixture), panorama());
      expect(ImmersiveXmp.parse(fixture), isA<PanoramaXmp>());
      expect(fixture, contains('GPano:ProjectionType="equirectangular"'));
      expect(PanoramaXmp.parse(fixture)!.description, contains(panoramaHonesty));
      expect(PanoramaXmp.parse(fixture)!.inventedFraction, closeTo(0.92, 1e-12));
    });

    test('a 360° 3D panorama writes xmp_v1_stereo_panorama_sample.xmp byte for byte, and names its mono one', () {
      final fixture = _fixture('xmp_v1_stereo_panorama_sample.xmp');
      final read = StereoPanoramaXmp.parse(fixture)!;

      expect(stereoPanorama().toXml(), fixture);
      expect(read, stereoPanorama());
      expect(read.parentDerivativeId, panorama().derivativeId);
      expect(read.isGenerated, isTrue);
      expect(read.relief, ImmersiveOrigin.estimatedDepth);
      expect(read.region, region);
      // A version of the photo itself, as its mono panorama
      expect(read.sourceSha1, salon.sha1);
    });

    test('the 3D version of a 360° photo of the user says its relief was estimated, nothing was generated', () {
      final real = StereoPanoramaXmp.estimated(
        width: 4096,
        height: 4096,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'PANO_0001.jpg',
        sourceSize: 10,
        sourceSha1: salon.sha1,
        sourceQuarterTurns: 0,
        created: created,
        creatorTool: tool,
      );
      final read = StereoPanoramaXmp.parse(real.toXml())!;

      expect(read.origin, ImmersiveOrigin.estimatedDepth);
      expect(read.relief, isNull);
      expect(read.isGenerated, isFalse);
      expect(read.parentDerivativeId, isNull);
      expect(read.description, stereo360Description);
      expect(read.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
    });

    test('the scene of the sample is the request of the stereoPair contract', () {
      final contract =
          jsonDecode(File('$_fixtures/stereo_pair_contract_v1.json').readAsStringSync()) as Map<String, dynamic>;
      final design = ((contract['volumetricScene'] as List).first as Map<String, dynamic>)['request'];

      expect(scene().request!.toJson(), design);
      // A scene of a later format of the tail asks nothing of the headset
      expect(
        SceneXmp.parse(_fixture('xmp_v1_scene_sample.xmp').replaceAll('glb-layers-v1', 'glb-layers-v2'))!.request,
        isNull,
      );
    });
  });

  group('the settings keys, one per kind', () {
    test('a scene: the sums of its two models, the pipeline, the step of the grid and the quarter turns', () {
      expect(scene().settingsKey, '${scene().geometryModelSha256}|${scene().inpaintModelSha256}|scene-v1|4|0');
    });

    test('a scene of a square photo: its grid at 5, written in the packet and in the key', () {
      final square = scene(width: 1024, height: 1024);
      final read = SceneXmp.parse(square.toXml())!;

      expect(square.toXml(), contains('Immuch360:GridStep="5"'));
      expect(read.gridStep, 5);
      expect(read.settingsKey, '${square.geometryModelSha256}|${square.inpaintModelSha256}|scene-v1|5|0');
      expect(read.settingsKey, isNot(scene().settingsKey));
      // A quarter turn keeps the step
      expect(scene(width: 768, height: 1024).gridStep, 4);
    });

    test('a panorama: the sums of the transformer and of the LoRA, the pipeline, the steps; never the seed', () {
      final other = PanoramaXmp.parse(panorama().toXml().replaceAll('1234567890', '42'))!;

      expect(panorama().settingsKey, '${panorama().generatorSha256}|${panorama().generatorLoraSha256}|pano-v1|28|0');
      expect(other.settingsKey, panorama().settingsKey);
    });

    test('a 360° 3D panorama: the sum of the depth model, the pipeline, the largest shift', () {
      expect(stereoPanorama().settingsKey, '$depthModelOnnxSha256|relief-360-v1|1.0|0');
    });

    test('a part missing gives none', () {
      expect(const SceneXmp(pipeline: SceneV1.pipeline).settingsKey, isNull);
      expect(const PanoramaXmp(steps: 28).settingsKey, isNull);
      expect(const StereoPanoramaXmp(maxShiftDegrees: 1).settingsKey, isNull);
    });
  });

  group('a build of phase 1 reads every kind without mistaking it', () {
    Uint8List head(String packet) => Uint8List.fromList([0xff, 0xd8, ...xmpApp1Segment(packet), 0xff, 0xd9]);

    test('the probe of the 3D photos returns null for a scene: a flat photo', () {
      final bytes = head(scene().toXml());
      final xmp = StereoPhotoXmp.findIn(bytes)!;
      final text = latin1.decode(bytes);

      expect(xmp.kind, ImmersiveKind.volumetricScene);
      expect(xmp.isReadableStereoPhoto, isFalse);
      expect(parseGPanoProjectionType(text), isNull);
      expect(decideStereoPhoto(name: 'salon_scene3D.jpg', width: 2048, height: 1536, xmp: xmp), isNull);
    });

    test('the probe returns null for a panorama, which the 360° rules take, over the whole sphere', () {
      final bytes = head(panorama().toXml());
      final text = latin1.decode(bytes);
      final xmp = StereoPhotoXmp.findIn(bytes)!;

      expect(xmp.kind, ImmersiveKind.panorama360);
      expect(parseGPanoProjectionType(text), 'equirectangular');
      expect(decideStereoPhoto(name: 'salon_360.jpg', width: 8192, height: 4096, xmp: xmp, isSphere: true), isNull);
      final crop = parseGPanoCrop(text)!;
      expect(isPartialSphere(crop), isFalse);
      // No initial view: the viewers open on the centre column, the photo
      expect(parseGPanoInitialView(text), isNull);
      expect(guessStereoLayout(width: 8192, height: 4096, hasGPanoCrop: isPartialSphere(crop)), StereoLayout.mono);
    });

    test('a 360° 3D panorama is a sphere of two eyes stacked, the left one on top', () {
      final bytes = head(stereoPanorama().toXml());
      final text = latin1.decode(bytes);
      final xmp = StereoPhotoXmp.findIn(bytes)!;

      expect(xmp.kind, ImmersiveKind.stereoPanorama360);
      expect(parseGPanoProjectionType(text), 'equirectangular');
      expect(isPartialSphere(parseGPanoCrop(text)!), isFalse);
      expect(decideStereoPhoto(name: 'salon_360_3D.jpg', width: 4096, height: 4096, xmp: xmp, isSphere: true), isNull);
      expect(guessStereoLayout(width: 4096, height: 4096), StereoLayout.topBottom);
      expect(guessSphereCoverage(fileName: 'salon_360_3D.jpg', width: 4096, height: 4096), SphereCoverage.full);
    });

    test('the common fields read the same for every kind: the library links them to their original', () {
      for (final packet in [scene().toXml(), panorama().toXml(), stereoPanorama().toXml()]) {
        final xmp = StereoPhotoXmp.parse(packet)!;

        expect(xmp.sourceSha1, salon.sha1);
        expect(xmp.sourceName, salon.name);
        expect(xmp.sourceSize, salon.size);
        expect(xmp.derivativeId, startsWith('urn:uuid:'));
        expect(xmp.formatVersion, 1);
        expect(xmp.isNewerFormat, isFalse);
      }
    });

    test('the names never read as a side by side photo, and a scene never as 360°', () {
      expect(sideBySideOrderOfName('salon_scene3D.jpg'), isNull);
      expect(isStereoPhotoCandidate(name: 'salon_scene3D.jpg', width: 2048, height: 1536), isFalse);
      expect(nameSays360('salon_scene3D.jpg'), isFalse);
      expect(nameSays360(derivedFileNameFor(ImmersiveKind.panorama360, 'salon.jpg')), isTrue);
    });
  });

  group('Immuch360:Sources is reserved', () {
    String withSources(String packet) => packet.replaceFirst(
      '   <dc:description>',
      '   <Immuch360:Sources><rdf:Seq><rdf:li>X8tYgvibyzHDDN2yXGU/ft1XxeM&#x3D;</rdf:li>'
          '<rdf:li>AAAAAAAAAAAAAAAAAAAAAAAAAAA&#x3D;</rdf:li></rdf:Seq></Immuch360:Sources>\n'
          '   <dc:description>',
    );

    test('ignored by the reader of phase 1', () {
      for (final packet in [scene().toXml(), panorama().toXml(), _fixture('xmp_v1_sample.xmp')]) {
        expect(StereoPhotoXmp.parse(withSources(packet)), StereoPhotoXmp.parse(packet));
      }
    });

    test('read, never written', () {
      final read = SceneXmp.parse(withSources(scene().toXml()))!;

      expect(read.sources, ['X8tYgvibyzHDDN2yXGU/ft1XxeM=', 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=']);
      expect(read.toXml(), isNot(contains('Sources')));
      expect(scene().sources, isEmpty);
    });
  });

  group('the writer', () {
    test('never puts a GPano value through an entity', () {
      expect(
        () => xmpPacket(
          namespaces: const [(gpanoPrefix, gpanoNamespace)],
          attributes: const [XmpAttribute('GPano:ProjectionType', 'equi=rect', literal: true)],
        ),
        throwsArgumentError,
      );
    });

    test('ImmersiveXmp reads each kind with its class, and a 3D photo or an unknown kind as in phase 1', () {
      final photo = _fixture('xmp_v1_sample.xmp');

      expect(ImmersiveXmp.parse(photo), StereoPhotoXmp.parse(photo));
      final later = ImmersiveXmp.parse(photo.replaceAll('"StereoPhoto"', '"Hologram"'))!;
      expect(later, isA<StereoPhotoXmp>());
      expect(later.kind, isNull);
      expect(ImmersiveXmp.parse('<x:xmpmeta/>'), isNull);
      expect(ImmersiveXmp.findIn(Uint8List.fromList(utf8.encode('no packet'))), isNull);
      expect(ImmersiveXmp.findIn(Uint8List.fromList([0xff, 0xd8, ...xmpApp1Segment(panorama().toXml())])), panorama());
    });

    test('a packet read from a file keeps its fields when another tool turned the attributes into elements', () {
      final elements = panorama().toXml().replaceAllMapped(
        RegExp(r'\n    (Immuch360:(?:Seed|Steps|PhotoHfov))="([^"]*)"'),
        (match) => '',
      );
      final read = PanoramaXmp.parse(
        elements.replaceFirst(
          '   <dc:description>',
          '   <Immuch360:Seed>1234567890</Immuch360:Seed>\n   <Immuch360:Steps>28</Immuch360:Steps>\n'
              '   <Immuch360:PhotoHfov>65.4</Immuch360:PhotoHfov>\n   <dc:description>',
        ),
      )!;

      expect(read, panorama());
    });
  });
}
