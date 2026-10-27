// The 3D versions an original already has (design-final 2026-10-26, section 2.6.1): looked up in the library index
// first, then among the neighbours of the destination folder whose name starts like a version (five at most, 128 KiB
// read each), so that a drive or a NAS not scanned again yet is covered too. Close names never mislead the search, and
// a file is only taken for a version once its own XMP says so.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

const _sum = 'X8tYgvibyzHDDN2yXGU/ft1XxeM=';
const _otherSum = 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _size = 4182311;

/// The index of the library as lot A6a fills it: the paths of the files whose XMP names an original, by its sum
class _Index implements DerivedVersionIndex {
  _Index(this.paths, {this.error});

  final Map<String, List<String>> paths;

  /// Thrown by each question: the database closed
  final Error? error;
  final asked = <String>[];

  @override
  Future<List<String>> versionPathsOf(String sourceSha1) async {
    asked.add(sourceSha1);
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return paths[sourceSha1] ?? const [];
  }
}

void main() {
  late Directory root;
  late String photos;
  late String elsewhere;
  late List<String> read;

  setUp(() {
    root = Directory.systemTemp.createTempSync('existing_versions');
    photos = p.join(root.path, 'photos');
    elsewhere = p.join(root.path, 'elsewhere');
    Directory(photos).createSync();
    Directory(elsewhere).createSync();
    read = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// A 3D photo of ours at [folder]/[name], made from the original of [sha1] with [turns]
  String version(
    String folder,
    String name, {
    String? sha1 = _sum,
    int turns = 0,
    String sourceName = 'salon.jpg',
    int sourceSize = _size,
    String? derivativeId = 'urn:uuid:11111111-0000-4000-8000-000000000000',
    double parallax = ReliefV1.parallax,
  }) {
    final xmp = StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: sourceName,
      sourceSize: sourceSize,
      sourceSha1: sha1 ?? '',
      sourceQuarterTurns: turns,
      created: '2026-10-27T10:12:00+01:00',
      creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      derivativeId: derivativeId,
      parallax: parallax,
    );
    final packet = derivativeId == null
        ? xmp.toXml().replaceAll(RegExp(r'\s+Immuch360:DerivativeId="[^"]*"'), '')
        : xmp.toXml();
    // The head of a JPEG is all the finder reads
    final file = File(p.join(folder, name))..writeAsBytesSync([0xff, 0xd8, ...xmpApp1Segment(packet), 0xff, 0xd9]);
    return file.path;
  }

  ExistingVersionFinder finder({DerivedVersionIndex? index}) => ExistingVersionFinder(
    index: index,
    readHead: (path) async {
      read.add(p.basename(path));
      return readFileHead(path);
    },
  );

  const original = DerivedRuleOriginal(name: 'salon.jpg', size: _size, sha1: _sum);
  final sameSettings = versionSettingsKey(depthModelSha256: depthModelOnnxSha256);

  test('the settings compared are those of the XMP: model, pipeline, parallax, convergence and quarter turns', () {
    expect(
      sameSettings,
      StereoPhotoXmp.estimated(
        eyeWidth: 1,
        eyeHeight: 1,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'a.jpg',
        sourceSize: 1,
        sourceSha1: _sum,
        sourceQuarterTurns: 0,
        created: '',
        creatorTool: '',
      ).settingsKey,
    );
    expect(versionSettingsKey(depthModelSha256: depthModelOnnxSha256, quarterTurns: 1), isNot(sameSettings));
    expect(
      versionSettingsKey(depthModelSha256: depthModelOnnxSha256, quarterTurns: 5),
      versionSettingsKey(depthModelSha256: depthModelOnnxSha256, quarterTurns: 1),
    );
    expect(versionSettingsKey(depthModelSha256: depthModelTfliteSha256), isNot(sameSettings));
    expect(versionSettingsKey(depthModelSha256: depthModelOnnxSha256, parallax: 0.03), isNot(sameSettings));
  });

  group('versionsOf', () {
    test('takes the versions the index knows first, wherever they are, then the neighbours of the folder', () async {
      final indexed = version(elsewhere, 'moved.jpg');
      final neighbour = version(photos, 'salon_3D_LRF_Full_SBS.jpg', turns: 1);
      final index = _Index({
        _sum: [indexed],
      });

      final found = await finder(index: index).versionsOf(original, folder: photos).toList();

      expect(found.map((version) => version.path), [indexed, neighbour]);
      expect(found.first.xmp.sourceSha1, _sum);
      expect(found.last.xmp.sourceQuarterTurns, 1);
      expect(index.asked, [_sum]);
    });

    test('only in the folder: what the index knows elsewhere is left out, and not even read', () async {
      final moved = version(elsewhere, 'salon_3D_LRF_Full_SBS.jpg');
      final here = version(photos, 'salon_3D_LRF_Full_SBS (1).jpg');
      final index = _Index({
        _sum: [moved, here],
      });

      final found = await finder(index: index).versionsOf(original, folder: photos, onlyInFolder: true).toList();

      expect(found.map((version) => version.path), [here]);
      expect(read, ['salon_3D_LRF_Full_SBS (1).jpg']);
      expect(
        (await finder(index: index).withSettings(original, sameSettings, folder: photos, onlyInFolder: true))?.path,
        here,
      );
      expect((await finder(index: index).withSettings(original, sameSettings, folder: photos))?.path, moved);
    });

    test('an index that fails is passed over: the neighbours still tell', () async {
      final neighbour = version(photos, 'salon_3D_LRF_Full_SBS.jpg');
      final index = _Index(const {}, error: StateError('The database is closed'));

      final found = await finder(index: index).versionsOf(original, folder: photos).toList();

      expect(found.map((version) => version.path), [neighbour]);
      expect(index.asked, [_sum]);
    });

    test('a file the index still lists but that is gone, changed or made from another photo is no version', () async {
      final gone = p.join(elsewhere, 'gone_3D_LRF_Full_SBS.jpg');
      final foreign = p.join(elsewhere, 'foreign.jpg');
      File(foreign).writeAsBytesSync(List.filled(64, 7));
      final other = version(elsewhere, 'other.jpg', sha1: _otherSum);
      final index = _Index({
        _sum: [gone, foreign, other],
      });

      expect(await finder(index: index).versionsOf(original, folder: photos).toList(), isEmpty);
    });

    test('close names never mislead it, and at most five neighbours are read', () async {
      version(photos, 'salon2_3D_LRF_Full_SBS.jpg');
      version(photos, 'salon_3D_LRF_Full_SBS (1).jpg', sha1: _otherSum);
      final kept = version(photos, 'salon_3D_LRF_Full_SBS (2).jpg');
      File(p.join(photos, 'salon.jpg')).writeAsBytesSync(List.filled(16, 1));
      File(p.join(photos, 'salon_3D_LRF_Full_SBS.txt')).writeAsStringSync('not a photo');
      for (var i = 3; i < 9; i++) {
        version(photos, 'salon_3D_LRF_Full_SBS ($i).jpg', sha1: _otherSum);
      }

      final found = await finder().versionsOf(original, folder: photos).toList();

      expect(found.map((version) => version.path), [kept]);
      expect(read, hasLength(maxDerivedCandidates));
      expect(read, isNot(contains('salon2_3D_LRF_Full_SBS.jpg')));
      expect(read, isNot(contains('salon.jpg')));
    });

    test('a file listed by the index and found among the neighbours is read once', () async {
      final both = version(photos, 'salon_3D_LRF_Full_SBS.jpg');

      final found = await finder(
        index: _Index({
          _sum: [both],
        }),
      ).versionsOf(original, folder: photos).toList();

      expect(found.map((version) => version.path), [both]);
      expect(read, ['salon_3D_LRF_Full_SBS.jpg']);
    });

    test('without the sum of the original: same folder, name, SourceName and SourceSize', () async {
      final kept = version(photos, 'salon_3D_LRF_Full_SBS.jpg', sha1: null);
      version(photos, 'salon_3D_LRF_Full_SBS (1).jpg', sha1: null, sourceSize: 12);
      version(elsewhere, 'salon_3D_LRF_Full_SBS.jpg', sha1: null);
      const unhashed = DerivedRuleOriginal(name: 'salon.jpg', size: _size);

      expect(
        (await finder()
                .versionsOf(
                  DerivedRuleOriginal(name: unhashed.name, size: unhashed.size, folder: photos),
                  folder: photos,
                )
                .toList())
            .map((version) => version.path),
        [kept],
      );
      expect(await finder().versionsOf(unhashed, folder: elsewhere).toList(), isEmpty);
    });

    test('a folder that cannot be listed, or no folder, gives what the index knows', () async {
      final indexed = version(elsewhere, 'salon_3D_LRF_Full_SBS.jpg');
      final index = _Index({
        _sum: [indexed],
      });

      expect(
        (await finder(index: index).versionsOf(original, folder: p.join(root.path, 'missing')).toList()).length,
        1,
      );
      expect((await finder(index: index).versionsOf(original).toList()).length, 1);
    });
  });

  group('withSettings', () {
    test('gives the first version made with the same settings, and reads no further', () async {
      version(photos, 'salon_3D_LRF_Full_SBS (1).jpg', turns: 1);
      final same = version(photos, 'salon_3D_LRF_Full_SBS (2).jpg');
      version(photos, 'salon_3D_LRF_Full_SBS.jpg');

      final found = await finder().withSettings(original, sameSettings, folder: photos);

      expect(found?.path, same);
      // The neighbours are read in the order of their names
      expect(read, ['salon_3D_LRF_Full_SBS (1).jpg', 'salon_3D_LRF_Full_SBS (2).jpg']);
    });

    test('none when the versions differ by their settings', () async {
      version(photos, 'salon_3D_LRF_Full_SBS.jpg', turns: 2);
      version(photos, 'salon_3D_LRF_Full_SBS (1).jpg', parallax: 0.04);

      expect(await finder().withSettings(original, sameSettings, folder: photos), isNull);
    });
  });

  test('readFileHead reads the first 128 KiB only: a packet further away is not seen', () async {
    final xmp = StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: 'salon.jpg',
      sourceSize: _size,
      sourceSha1: _sum,
      sourceQuarterTurns: 0,
      created: '',
      creatorTool: '',
    );
    final near = File(p.join(photos, 'near.jpg'))
      ..writeAsBytesSync([...xmpApp1Segment(xmp.toXml()), ...List.filled(200 * 1024, 0)]);
    final far = File(p.join(photos, 'far.jpg'))
      ..writeAsBytesSync([...List.filled(versionHeadLength, 0), ...xmpApp1Segment(xmp.toXml())]);

    expect((await readFileHead(near.path))!.length, versionHeadLength);
    expect(StereoPhotoXmp.findIn((await readFileHead(near.path))!), isNotNull);
    expect(StereoPhotoXmp.findIn((await readFileHead(far.path))!), isNull);
    expect(await readFileHead(p.join(photos, 'none.jpg')), isNull);
  });
}
