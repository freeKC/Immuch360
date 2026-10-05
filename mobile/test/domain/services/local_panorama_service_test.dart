import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

import '../../fixtures/raw/insta360.stub.dart';
import 'spherical_probe_fixtures.dart';

// GPano XMP as cameras write it, attributes on rdf:Description
String _cameraXmp({String projection = 'equirectangular', String crop = ''}) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF><rdf:Description rdf:about="" '
    'xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" GPano:ProjectionType="$projection" '
    'GPano:UsePanoramaViewer="True" $crop/></rdf:RDF></x:xmpmeta>';

// The crop of a VR180 photo: half the width of the full panorama, all of its height
const _halfSphereCrop =
    'GPano:FullPanoWidthPixels="8000" GPano:FullPanoHeightPixels="4000" GPano:CroppedAreaLeftPixels="2000" '
    'GPano:CroppedAreaTopPixels="0" GPano:CroppedAreaImageWidthPixels="4000" GPano:CroppedAreaImageHeightPixels="4000"';

// A crop over the whole sphere, as many cameras write on full spheres
const _fullSphereCrop =
    'GPano:FullPanoWidthPixels="8000" GPano:FullPanoHeightPixels="4000" GPano:CroppedAreaLeftPixels="0" '
    'GPano:CroppedAreaTopPixels="0" GPano:CroppedAreaImageWidthPixels="8000" GPano:CroppedAreaImageHeightPixels="4000"';

// A JPEG-like file: a few bytes, the XMP at [xmpOffset], then filler up to [length]
Uint8List _photo(String xmp, {int xmpOffset = 100, int length = 4096}) {
  final bytes = Uint8List(length);
  bytes.setAll(xmpOffset, latin1.encode(xmp));
  return bytes;
}

// Reads [bytes] as a file would, counting the reads in [reads]
ByteRangeReader _reader(Uint8List bytes, [List<int>? reads]) => (offset, length) async {
  reads?.add(offset);
  final start = offset.clamp(0, bytes.length);
  final end = (offset + length).clamp(0, bytes.length);
  return Uint8List.sublistView(bytes, start, end);
};

final _base = DateTime(2024, 6, 1);

LocalAsset _asset(
  String id, {
  String? name,
  AssetType type = AssetType.image,
  int? width = 4000,
  int? height = 2000,
  int age = 0,
  DateTime? updatedAt,
}) => LocalAsset(
  id: id,
  name: name ?? '$id.jpg',
  type: type,
  // The higher the age, the older
  createdAt: _base.subtract(Duration(days: age)),
  updatedAt: updatedAt ?? _base.subtract(Duration(days: age)),
  width: width,
  height: height,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('parseGPanoProjectionType', () {
    test('reads the projection in both tag styles', () {
      expect(parseGPanoProjectionType(_cameraXmp()), 'equirectangular');
      expect(parseGPanoProjectionType('<GPano:ProjectionType>cylindrical</GPano:ProjectionType>'), 'cylindrical');
      expect(parseGPanoProjectionType("GPano:ProjectionType = 'EQUIRECTANGULAR'"), 'EQUIRECTANGULAR');
    });

    test('is null without the tag', () {
      expect(parseGPanoProjectionType(''), isNull);
      expect(parseGPanoProjectionType('GPano:UsePanoramaViewer="True" ProjectionType="equirectangular"'), isNull);
    });
  });

  group('readGPanoTags', () {
    test('finds the tags at the head of the file with one read', () async {
      final reads = <int>[];
      final bytes = _photo(_cameraXmp(crop: _halfSphereCrop), length: 300000);

      final tags = await readGPanoTags(_reader(bytes, reads), bytes.length);

      expect(tags?.projectionType, 'equirectangular');
      expect(tags?.crop, const Rect.fromLTWH(0.25, 0, 0.5, 1));
      expect(reads, [0]);
    });

    test('falls back to the tail of the file', () async {
      final reads = <int>[];
      final bytes = _photo(_cameraXmp(), xmpOffset: 290000, length: 300000);

      final tags = await readGPanoTags(_reader(bytes, reads), bytes.length);

      expect(tags?.projectionType, 'equirectangular');
      expect(reads, [0, 300000 - 131072]);
    });

    test('reads a small file once, and is null without GPano tags', () async {
      final reads = <int>[];
      final bytes = _photo('<x:xmpmeta>nothing here</x:xmpmeta>');

      expect(await readGPanoTags(_reader(bytes, reads), bytes.length), isNull);
      expect(reads, [0]);
    });
  });

  group('isLocalPanoramaCandidate', () {
    test('takes 2:1 frames within 2 percent, photos and videos', () {
      expect(isLocalPanoramaCandidate(_asset('a', width: 5760, height: 2880)), isTrue);
      expect(isLocalPanoramaCandidate(_asset('b', width: 4000, height: 1961)), isTrue, reason: '2.04:1');
      expect(isLocalPanoramaCandidate(_asset('c', type: AssetType.video, width: 3840, height: 1920)), isTrue);
      expect(isLocalPanoramaCandidate(_asset('d', width: 4000, height: 3000)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('e', width: 2400, height: 1080)), isFalse, reason: '2.22:1');
      expect(isLocalPanoramaCandidate(_asset('f', width: 1080, height: 2160)), isFalse, reason: '1:2, no 3D name');
    });

    test('takes the names that say 360°, whatever the frame', () {
      for (final name in [
        'trip_360.jpg',
        '360_0001.JPG',
        'GS010001.360',
        'PANO_20240101.jpg',
        'PXL_20240101_PANO.jpg',
        'beach panorama.jpg',
        'IMG_VR180.jpg',
        'IMG_20240101_120000_00_001.insp',
        'VID_20240101_120000_00_001.INSV',
        'CAM_20250715191201_0003_D.OSV',
        'GS__0001.36P',
      ]) {
        expect(isLocalPanoramaCandidate(_asset('a', name: name, width: 4000, height: 3000)), isTrue, reason: name);
      }
    });

    test('does not take 360 within a longer number', () {
      for (final name in ['IMG_1360.JPG', '20240613_103600.jpg', 'IMG_3601.jpg']) {
        expect(isLocalPanoramaCandidate(_asset('a', name: name, width: 4000, height: 3000)), isFalse, reason: name);
      }
    });

    test('takes square and 1:2 frames only with a 3D or VR180 name', () {
      expect(isLocalPanoramaCandidate(_asset('a', name: 'trip_3D.jpg', width: 4000, height: 4000)), isTrue);
      expect(isLocalPanoramaCandidate(_asset('b', name: 'trip-180x180.mp4', width: 2000, height: 4000)), isTrue);
      expect(isLocalPanoramaCandidate(_asset('c', name: 'IMG_3D41.JPG', width: 4000, height: 4000)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('d', name: 'IMG_0001.JPG', width: 4000, height: 4000)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('e', name: 'trip_3D.jpg', width: 4000, height: 3000)), isFalse);
    });

    test('needs the dimensions, and a photo or a video', () {
      expect(isLocalPanoramaCandidate(_asset('a', width: null, height: null)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('b', width: 4000, height: 0)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('c', type: AssetType.audio, width: 4000, height: 2000)), isFalse);
      expect(isLocalPanoramaCandidate(_asset('d', type: AssetType.other, name: 'x_360.bin')), isFalse);
    });
  });

  group('probeLocalPanoramaPhoto', () {
    Future<LocalPanoramaProbe> probe(Uint8List bytes) => probeLocalPanoramaPhoto(_reader(bytes), bytes.length);

    test('takes an equirectangular projection for 360°, in any case', () async {
      expect(await probe(_photo(_cameraXmp())), (isPanorama: true, halfSphere: null, raw360: false));
      expect(await probe(_photo(_cameraXmp(projection: 'Equirectangular'))), (
        isPanorama: true,
        halfSphere: null,
        raw360: false,
      ));
    });

    test('tells the half sphere from the crop', () async {
      expect(await probe(_photo(_cameraXmp(crop: _halfSphereCrop))), (
        isPanorama: true,
        halfSphere: true,
        raw360: false,
      ));
      expect(await probe(_photo(_cameraXmp(crop: _fullSphereCrop))), (
        isPanorama: true,
        halfSphere: false,
        raw360: false,
      ));
    });

    test('takes other projections, and no GPano tags, for no 360°', () async {
      expect(await probe(_photo(_cameraXmp(projection: 'cylindrical'))), (
        isPanorama: false,
        halfSphere: null,
        raw360: false,
      ));
      expect(await probe(_photo('<GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>')), (
        isPanorama: false,
        halfSphere: null,
        raw360: false,
      ));
      expect(await probe(_photo('')), (isPanorama: false, halfSphere: null, raw360: false));
    });

    test('takes a photo that ends with the trailer of an Insta360 camera for a raw dual fisheye one', () async {
      final raw = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: _photo('', length: 200000));

      expect(await probe(raw), (isPanorama: true, halfSphere: null, raw360: true));
    });

    test('takes a photo whose trailer says the camera stitched it for an equirect one, unless named .insp', () async {
      // Field 129 of the metadata: 6 an equirect picture stitched in the camera, 2 a double fisheye
      Uint8List photo(int? imageCategory) => insta360File([
        insta360Record(1, x5Metadata(imageCategory: imageCategory), format: 1),
      ], body: _photo('', length: 200000));
      Future<LocalPanoramaProbe> read(Uint8List bytes, String name) =>
          probeLocalPanoramaPhoto(_reader(bytes), bytes.length, name: name);

      expect(await read(photo(6), 'IMG_20240101_120000_00_001.jpg'), (
        isPanorama: true,
        halfSphere: false,
        raw360: false,
      ));
      expect(await read(photo(2), 'IMG_20240101_120000_00_001.jpg'), (
        isPanorama: true,
        halfSphere: null,
        raw360: true,
      ));
      expect(await read(photo(null), 'IMG.jpg'), (isPanorama: true, halfSphere: null, raw360: true));
      expect(await read(photo(6), 'IMG_20240101_120000_00_001.insp'), (
        isPanorama: true,
        halfSphere: null,
        raw360: true,
      ));
    });

    test('takes a 2:1 photo of a 360° camera without GPano tags for a 360° one, by its EXIF and its size', () async {
      // The fixture writes every text out of its EXIF entry: a make of more than 3 letters ("DJI" fits in the entry)
      Uint8List photo(String make, String model, {int? width, int? height}) =>
          Uint8List.fromList([...insta360PhotoHead(make: make, model: model, pixelWidth: width, pixelHeight: height)]);
      const equirect = (isPanorama: true, halfSphere: false, raw360: false);
      const flat = (isPanorama: false, halfSphere: null, raw360: false);
      Future<LocalPanoramaProbe> read(Uint8List bytes, {int? width, int? height}) =>
          probeLocalPanoramaPhoto(_reader(bytes), bytes.length, name: 'DJI_0001.JPG', width: width, height: height);

      expect(await read(photo('DJI Ltd', 'Osmo 360', width: 15520, height: 7760)), equirect);
      expect(await read(photo('GoPro', 'GoPro Max'), width: 5760, height: 2880), equirect, reason: 'the asset size');
      expect(await read(photo('DJI Ltd', 'Osmo 360', width: 6400, height: 4800)), flat, reason: 'a single lens');
      expect(await read(photo('Apple', 'iPhone 15', width: 8000, height: 4000)), flat, reason: 'no 360° camera');
      expect(await read(photo('GoPro', 'GoPro Max')), flat, reason: 'no size known');
    });
  });

  group('probeLocalPanoramaFile', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('local_panorama_test');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    String write(String name, List<int> bytes) {
      final file = File('${directory.path}/$name')..writeAsBytesSync(bytes);
      return file.path;
    }

    test('reads the GPano XMP of a photo', () async {
      final path = write('pano.jpg', _photo(_cameraXmp(crop: _halfSphereCrop), length: 200000));

      expect(await probeLocalPanoramaFile(path, isVideo: false), (isPanorama: true, halfSphere: true, raw360: false));
    });

    test('reads the GPano tags the panorama viewer needs from a photo only on the device', () async {
      const initialView = 'GPano:InitialViewHeadingDegrees="90" GPano:InitialViewPitchDegrees="10"';
      final path = write('pano.jpg', _photo(_cameraXmp(crop: initialView), xmpOffset: 190000, length: 200000));

      final tags = await readGPanoFile(File(path));

      expect(tags?.projectionType, 'equirectangular');
      expect(tags?.crop, isNull);
      expect(tags?.initialView, (heading: 90.0, pitch: 10.0, poseHeading: 0.0));
      expect(await readGPanoFile(File(write('flat.jpg', _photo('')))), isNull);
    });

    test('takes a photo named .insp, and a video named .insv, .360 or .osv, for raw files, by their names', () async {
      const raw = (isPanorama: true, halfSphere: null, raw360: true);
      // A copy whose trailer was cut is still raw by its name
      final photo = write('IMG_001.insp', _photo(''));
      final sideBySide = write('VID_00_002.insv', mp4File(mp4Moov([mp4VideoTrack([], width: 5760, height: 2880)])));
      final split = write('VID_10_002.insv', mp4File(mp4Moov([mp4VideoTrack([], width: 2880, height: 2880)])));

      expect(await probeLocalPanoramaFile(photo, isVideo: false), raw);
      expect(await probeLocalPanoramaFile(sideBySide, isVideo: true), raw);
      expect(await probeLocalPanoramaFile(split, isVideo: true), raw, reason: 'its layout is settled when it opens');
      // Not read at all: the files do not even exist
      for (final name in ['GS010013.360', 'CAM_20250715191201_0003_D.OSV', 'VID_20240908_193126_10_004.insv']) {
        expect(await probeLocalPanoramaFile('${directory.path}/$name', isVideo: true), raw, reason: name);
      }
    });

    test('takes a .36p photo of the GoPro MAX 2 for a 360° photo without reading it, not raw', () async {
      expect(await probeLocalPanoramaFile('${directory.path}/GS__0001.36P', isVideo: false), (
        isPanorama: true,
        halfSphere: false,
        raw360: false,
      ));
    });

    test('takes a 2:1 JPEG of a 360° camera for a 360° photo, with the size of the asset', () async {
      final path = write(
        'DJI_0001.JPG',
        Uint8List.fromList([...insta360PhotoHead(make: 'DJI Ltd', model: 'Osmo 360'), ...List.filled(1000, 0)]),
      );

      expect(await probeLocalPanoramaFile(path, isVideo: false, width: 15520, height: 7760), (
        isPanorama: true,
        halfSphere: false,
        raw360: false,
      ));
      expect(await probeLocalPanoramaFile(path, isVideo: false, width: 6400, height: 4800), (
        isPanorama: false,
        halfSphere: null,
        raw360: false,
      ));
    });

    test('reads the spherical metadata of a video', () async {
      final full = write(
        'full.mp4',
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dEquirectangular()]),
          ]),
          moovAtEnd: true,
        ),
      );
      final half = write(
        'half.mp4',
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dProjection(mp4Mshp())]),
          ]),
        ),
      );
      final flat = write('flat.mp4', mp4File(mp4Moov([mp4VideoTrack([])])));

      expect(await probeLocalPanoramaFile(full, isVideo: true), (isPanorama: true, halfSphere: false, raw360: false));
      expect(await probeLocalPanoramaFile(half, isVideo: true), (isPanorama: true, halfSphere: true, raw360: false));
      expect(await probeLocalPanoramaFile(flat, isVideo: true), (isPanorama: false, halfSphere: null, raw360: false));
    });

    test('reads files in a background isolate, null for a file that cannot be read', () async {
      final photo = write('pano.jpg', _photo(_cameraXmp()));
      final video = write('flat.mp4', mp4File(mp4Moov([mp4VideoTrack([])])));

      final probes = await probeLocalPanoramaFilesInBackground([
        (path: photo, isVideo: false, width: null, height: null),
        (path: '${directory.path}/missing.jpg', isVideo: false, width: null, height: null),
        (path: video, isVideo: true, width: null, height: null),
      ]);

      expect(probes, [
        (isPanorama: true, halfSphere: null, raw360: false),
        null,
        (isPanorama: false, halfSphere: null, raw360: false),
      ]);
    });
  });

  group('LocalPanoramaRecord', () {
    test('goes to JSON and back, in order, the half sphere left out when unknown', () {
      final records = {
        'b': LocalPanoramaRecord(isPanorama: true, halfSphere: true, checkedAt: DateTime(2024, 1, 2)),
        'a': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024, 1, 1)),
      };

      final json = encodeLocalPanoramaRecords(records);

      expect(jsonDecode(json), {
        'b': {'p': true, 'h': true, 't': DateTime(2024, 1, 2).millisecondsSinceEpoch, 'v': 2},
        'a': {'p': false, 't': DateTime(2024, 1, 1).millisecondsSinceEpoch, 'v': 2},
      });
      final decoded = decodeLocalPanoramaRecords(json);
      expect(decoded, records);
      expect(decoded.keys, ['b', 'a']);
    });

    test('keeps the raw flag of a raw dual fisheye file, and reads the records written before it', () {
      final records = {'raw': LocalPanoramaRecord(isPanorama: true, raw360: true, checkedAt: DateTime(2024, 1, 3))};

      final json = encodeLocalPanoramaRecords(records);

      expect(jsonDecode(json), {
        'raw': {'p': true, 'r': true, 't': DateTime(2024, 1, 3).millisecondsSinceEpoch, 'v': 2},
      });
      expect(decodeLocalPanoramaRecords(json), records);
      expect(decodeLocalPanoramaRecords('{"a":{"p":true,"t":5}}')['a']?.raw360, isFalse);
    });

    test('keeps the version of the rules, 0 for the records written before it, and writes those back the same', () {
      final records = {
        'new': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024, 1, 4)),
        'old': LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024, 1, 3), version: 0),
      };

      expect(records['new']?.version, LocalPanoramaRecord.currentVersion);
      expect(jsonDecode(encodeLocalPanoramaRecords(records)), {
        'new': {'p': false, 't': DateTime(2024, 1, 4).millisecondsSinceEpoch, 'v': 2},
        'old': {'p': false, 't': DateTime(2024, 1, 3).millisecondsSinceEpoch},
      });
      expect(decodeLocalPanoramaRecords(encodeLocalPanoramaRecords(records)), records);
      expect(decodeLocalPanoramaRecords('{"a":{"p":false,"t":5}}')['a']?.version, 0);
      expect(decodeLocalPanoramaRecords('{"a":{"p":false,"t":5,"v":"x"}}')['a']?.version, 0);
      expect(
        LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024), version: 0),
        isNot(LocalPanoramaRecord(isPanorama: false, checkedAt: DateTime(2024))),
      );
    });

    test('skips a damaged value, and anything but records in it', () {
      expect(decodeLocalPanoramaRecords(null), isEmpty);
      expect(decodeLocalPanoramaRecords('not json'), isEmpty);
      expect(decodeLocalPanoramaRecords('["a"]'), isEmpty);
      expect(decodeLocalPanoramaRecords('{"a":{"p":true,"t":5,"h":"x"},"b":{"p":"yes","t":5},"c":3}'), {
        'a': LocalPanoramaRecord(isPanorama: true, checkedAt: DateTime.fromMillisecondsSinceEpoch(5), version: 0),
      });
    });
  });

  group('LocalPanoramaService', () {
    late List<LocalAsset> assets;
    late Map<String, LocalPanoramaProbe?> probes;
    late List<String> read;
    late List<String> fileRequests;
    late DateTime now;

    setUp(() {
      assets = [];
      probes = {};
      read = [];
      fileRequests = [];
      now = DateTime(2024, 7, 1);
    });

    // The assets of the test, the newest first; the probe of a file is the one given in probes for its asset, else
    // no 360°. Files named "missing" are not found.
    LocalPanoramaService service({
      Future<bool> Function(String id)? isLocallyAvailable,
      int maxEntries = 2000,
      int maxFilesPerRun = 300,
      int pageSize = 3,
      int batchSize = 2,
    }) => LocalPanoramaService(
      assets: (offset, limit) async {
        final sorted = [...assets]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return sorted.skip(offset).take(limit).toList();
      },
      file: (id) async {
        fileRequests.add(id);
        return id.startsWith('missing') ? null : File('/files/$id');
      },
      isLocallyAvailable: isLocallyAvailable,
      probe: (files) async {
        final names = [for (final file in files) file.path.split('/').last];
        read.addAll(names);
        return [
          for (final name in names)
            probes.containsKey(name) ? probes[name] : (isPanorama: false, halfSphere: null, raw360: false),
        ];
      },
      now: () => now,
      maxEntries: maxEntries,
      maxFilesPerRun: maxFilesPerRun,
      pageSize: pageSize,
      batchSize: batchSize,
    );

    test('reads the candidates only, the newest first, and records what they declare', () async {
      assets = [
        _asset('old-pano', age: 3),
        _asset('flat', width: 4000, height: 3000, age: 2),
        _asset('video', type: AssetType.video, width: 3840, height: 1920, age: 1),
        _asset('new-pano', age: 0),
      ];
      probes = {
        'old-pano': (isPanorama: true, halfSphere: null, raw360: false),
        'video': (isPanorama: true, halfSphere: true, raw360: false),
      };
      final progress = <Map<String, LocalPanoramaRecord>>[];

      final records = await service().scan({}, onProgress: progress.add);

      expect(read, ['new-pano', 'video', 'old-pano']);
      expect(records, {
        'new-pano': LocalPanoramaRecord(isPanorama: false, checkedAt: now),
        'video': LocalPanoramaRecord(isPanorama: true, halfSphere: true, checkedAt: now, raw360: false),
        'old-pano': LocalPanoramaRecord(isPanorama: true, checkedAt: now),
      });
      expect(records.keys, ['new-pano', 'video', 'old-pano']);
      expect(progress.map((records) => records.length), [2, 3], reason: 'handed over at each batch of two files');
    });

    test('reads no file twice, unless the asset changed since', () async {
      assets = [_asset('a', age: 0), _asset('b', age: 1)];
      final scanner = service();
      final first = await scanner.scan({});
      expect(first.keys, ['a', 'b']);
      read.clear();

      expect(await scanner.scan(first), first);
      expect(read, isEmpty);

      now = DateTime(2024, 8, 1);
      assets = [_asset('a', age: 0, updatedAt: DateTime(2024, 7, 15)), _asset('b', age: 1)];
      probes = {'a': (isPanorama: true, halfSphere: null, raw360: false)};
      final second = await scanner.scan(first);

      expect(read, ['a']);
      expect(second['a'], LocalPanoramaRecord(isPanorama: true, checkedAt: now));
      expect(second.keys, ['b', 'a'], reason: 'the latest record goes last');
    });

    test('reads again once the records of older rules that the raw files of Insta360 cameras may change', () async {
      assets = [
        // A photo of an X3 renamed .jpg, its trailer kept, that build 15 found flat
        _asset('renamed', name: 'IMG_20240908_133036_00_001.jpg', width: 11968, height: 5984, age: 0),
        _asset(
          'insv',
          name: 'VID_20240908_133036_00_002.insv',
          type: AssetType.video,
          width: 5760,
          height: 2880,
          age: 1,
        ),
        _asset('insp', name: 'IMG_20240908_133036_00_003.insp', width: 6080, height: 3040, age: 2),
        // Read the same now: a photo whose GPano declared 360°, a video that is no raw one, a record of the current rules
        _asset('pano', age: 3),
        _asset('video', name: 'VID_20240908_140000.mp4', type: AssetType.video, width: 3840, height: 1920, age: 4),
        _asset('current', age: 5),
      ];
      // The store as build 15 left it: no version, no raw flag
      final checkedAt = DateTime(2024, 6, 15).millisecondsSinceEpoch;
      final known = decodeLocalPanoramaRecords(
        jsonEncode({
          'renamed': {'p': false, 't': checkedAt},
          'insv': {'p': false, 't': checkedAt},
          'insp': {'p': false, 't': checkedAt},
          'pano': {'p': true, 't': checkedAt},
          'video': {'p': false, 't': checkedAt},
          'current': {'p': false, 't': checkedAt, 'v': 2},
        }),
      );
      expect(known.values.map((record) => record.version), [0, 0, 0, 0, 0, 2]);
      probes = {
        for (final id in ['renamed', 'insv', 'insp']) id: (isPanorama: true, halfSphere: null, raw360: true),
      };
      final scanner = service();

      final records = await scanner.scan(known);

      expect(read, ['renamed', 'insv', 'insp']);
      for (final id in ['renamed', 'insv', 'insp']) {
        expect(records[id], LocalPanoramaRecord(isPanorama: true, raw360: true, checkedAt: now), reason: id);
      }
      for (final id in ['pano', 'video', 'current']) {
        expect(records[id], known[id], reason: id);
      }

      read.clear();
      expect(await scanner.scan(records), records);
      expect(read, isEmpty, reason: 'read again once');
    });

    test('reads again once the records of version 1 that the raw videos and camera photos may change', () async {
      assets = [
        // Build 17 found a split recording and two tracks flat, and never read a .360 or a .osv as raw
        _asset('split', name: 'VID_20240908_193126_10_004.insv', type: AssetType.video, width: 2880, height: 2880),
        _asset('osv', name: 'CAM_20250715191201_0003_D.OSV', type: AssetType.video, width: 3840, height: 3840, age: 1),
        // An equirect photo of a DJI camera without GPano tags, and a .36p
        _asset('dji', name: 'DJI_0001.JPG', width: 15520, height: 7760, age: 2),
        _asset('36p', name: 'GS__0001.36P', width: 7680, height: 3840, age: 3),
        // Read the same: a 360° photo, a flat video that is no raw one, a record of the current rules
        _asset('pano', age: 4),
        _asset('video', name: 'VID_001.mp4', type: AssetType.video, width: 3840, height: 1920, age: 5),
        _asset('current', name: 'IMG_0002.JPG', age: 7),
      ];
      final checkedAt = DateTime(2024, 6, 15).millisecondsSinceEpoch;
      final known = decodeLocalPanoramaRecords(
        jsonEncode({
          for (final id in ['split', 'osv', 'dji', '36p', 'video']) id: {'p': false, 't': checkedAt, 'v': 1},
          'pano': {'p': true, 't': checkedAt, 'v': 1},
          'current': {'p': false, 't': checkedAt, 'v': 2},
        }),
      );
      probes = {
        'split': (isPanorama: true, halfSphere: null, raw360: true),
        'osv': (isPanorama: true, halfSphere: null, raw360: true),
        'dji': (isPanorama: true, halfSphere: false, raw360: false),
        '36p': (isPanorama: true, halfSphere: false, raw360: false),
      };
      final scanner = service();

      final records = await scanner.scan(known);

      expect(read, ['split', 'osv', 'dji', '36p']);
      expect(records['split'], LocalPanoramaRecord(isPanorama: true, raw360: true, checkedAt: now));
      expect(records['dji'], LocalPanoramaRecord(isPanorama: true, halfSphere: false, checkedAt: now));
      for (final id in ['pano', 'video', 'current']) {
        expect(records[id], known[id], reason: id);
      }

      read.clear();
      expect(await scanner.scan(records), records);
      expect(read, isEmpty, reason: 'read again once');
    });

    test('takes the modification date for the check date when it is later, a clock set wrong', () async {
      final future = DateTime(2030);
      assets = [_asset('a', updatedAt: future)];
      final scanner = service();

      final records = await scanner.scan({});
      expect(records['a']?.checkedAt, future);

      read.clear();
      await scanner.scan(records);
      expect(read, isEmpty, reason: 'not read again at every run');
    });

    test('reads at most so many files per run, the newest first, and goes on at the next run', () async {
      assets = [for (var age = 0; age < 5; age++) _asset('a$age', age: age)];
      final scanner = service(maxFilesPerRun: 2);

      final first = await scanner.scan({});
      expect(read, ['a0', 'a1']);

      read.clear();
      final second = await scanner.scan(first);
      expect(read, ['a2', 'a3']);
      expect(second.keys, ['a0', 'a1', 'a2', 'a3']);
    });

    test('leaves the files in the cloud for later, and those it cannot find', () async {
      assets = [_asset('cloud', age: 0), _asset('missing', age: 1), _asset('here', age: 2)];

      final records = await service(isLocallyAvailable: (id) async => id != 'cloud').scan({});

      expect(read, ['here']);
      expect(records.keys, ['here']);
      expect(fileRequests, ['missing', 'here'], reason: 'the file of an asset in the cloud is not asked for');
    });

    test('reads again next time a file that could not be read', () async {
      assets = [_asset('a')];
      probes = {'a': null};

      final records = await service().scan({});

      expect(read, ['a']);
      expect(records, isEmpty);
    });

    test('drops the records of the assets that are gone, unless the database is empty', () async {
      final known = {
        'gone': LocalPanoramaRecord(isPanorama: true, checkedAt: now),
        'kept': LocalPanoramaRecord(isPanorama: true, checkedAt: now),
      };
      final scanner = service();

      expect(await scanner.scan(known), known, reason: 'nothing synced yet');

      assets = [_asset('kept')];
      expect((await scanner.scan(known)).keys, ['kept']);
      expect(read, isEmpty);
    });

    test('keeps the newest candidates only, past its limit', () async {
      assets = [
        for (var age = 0; age < 4; age++) _asset('a$age', age: age),
        _asset('flat', width: 4000, height: 3000, age: 1),
      ];
      final known = {'a3': LocalPanoramaRecord(isPanorama: true, checkedAt: now)};

      final records = await service(maxEntries: 2).scan(known);

      expect(read, ['a0', 'a1']);
      expect(records.keys, ['a0', 'a1']);
    });

    test('holds 2000 records at most, and reads 300 files per run, by default', () {
      final scanner = LocalPanoramaService(assets: (_, _) async => [], file: (_) async => null);
      expect(scanner.maxEntries, 2000);
      expect(scanner.maxFilesPerRun, 300);
    });
  });
}
