import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';

import 'phone_gallery_fakes.dart';

void main() {
  late Directory temp;
  late FakePhoneGallery gallery;
  late FakePhoneShareFiles files;
  late Set<String> panoramaIds;
  late DateTime now;
  late PhoneGalleryTree tree;

  File writeFile(String name, int length) {
    final file = File('${temp.path}/$name')..writeAsBytesSync(patternBytes(length));
    return file;
  }

  void addAsset(
    String id,
    String name, {
    AssetType type = AssetType.image,
    required DateTime createdAt,
    List<String> albums = const [],
    String? mimeType,
    String? servedName,
  }) {
    gallery.add(
      galleryAsset(id, name, type: type, createdAt: createdAt),
      albums: albums,
    );
    files.add(
      id,
      writeFile('$id.bin', 100 + id.length),
      mimeType: mimeType ?? (type == AssetType.video ? 'video/mp4' : 'image/jpeg'),
      fileName: servedName ?? name,
    );
  }

  List<String> namesOf(PhoneGalleryNode? node) => [
    for (final child in (node! as PhoneGalleryFolder).children) child.name,
  ];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('phone_gallery_tree_test');
    gallery = FakePhoneGallery();
    files = FakePhoneShareFiles();
    panoramaIds = {};
    now = DateTime.utc(2026, 10, 5, 8);
    tree = PhoneGalleryTree(source: gallery, files: files, panoramaIds: () => panoramaIds, clock: () => now);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('the root holds the three fixed folders', () async {
    final root = await tree.resolve('/');

    expect(root, isA<PhoneGalleryFolder>());
    expect(root!.path, '/');
    expect(namesOf(root), ['Albums', 'By month', '360']);
    expect(await tree.resolve(''), isA<PhoneGalleryFolder>());
  });

  test('lists the albums by name, with sanitized and unique names', () async {
    gallery.albumList.addAll([
      galleryAlbum('a1', 'Camera'),
      galleryAlbum('a2', 'Screenshots'),
      galleryAlbum('a3', 'Trips/2026'),
      galleryAlbum('a4', 'camera'),
      galleryAlbum('a5', '..'),
      galleryAlbum('a6', 'Tab\there'),
    ]);

    final albums = await tree.resolve('/Albums');

    expect(namesOf(albums), ['_', 'Camera', 'camera (2)', 'Screenshots', 'Tab_here', 'Trips_2026']);
    expect((albums! as PhoneGalleryFolder).children.first.path, '/Albums/_');
  });

  test('lists the photos and videos of an album, newest first, with unique names', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);
    addAsset('2', 'VID_0002.mp4', type: AssetType.video, createdAt: DateTime.utc(2026, 9, 2), albums: ['a1']);
    // The same name twice: the older one keeps it
    addAsset('3', 'img_0001.JPG', createdAt: DateTime.utc(2026, 9, 3), albums: ['a1']);
    addAsset('4', 'Song.mp3', type: AssetType.audio, createdAt: DateTime.utc(2026, 9, 4), albums: ['a1']);
    // Gone from the gallery since the last sync: the platform does not answer for it
    gallery.add(galleryAsset('5', 'Gone.jpg', createdAt: DateTime.utc(2026, 9, 5)), albums: ['a1']);

    final album = await tree.resolve('/Albums/Camera');

    expect(namesOf(album), ['img_0001 (2).JPG', 'VID_0002.mp4', 'IMG_0001.jpg']);
    final video = (album! as PhoneGalleryFolder).children[1] as PhoneGalleryFile;
    expect(video.path, '/Albums/Camera/VID_0002.mp4');
    expect(video.assetId, '2');
    expect(video.mimeType, 'video/mp4');
    expect(video.size, 101);
    expect(video.modified, DateTime.fromMillisecondsSinceEpoch(1757000000000, isUtc: true));
  });

  test('resolves a file of an album without case, and nothing for an unknown name', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);

    final file = await tree.resolve('/albums/camera/img_0001.JPG');

    expect(file, isA<PhoneGalleryFile>());
    expect((file! as PhoneGalleryFile).assetId, '1');
    expect(await tree.resolve('/Albums/Camera/IMG_0002.jpg'), isNull);
    expect(await tree.resolve('/Albums/Other'), isNull);
    expect(await tree.resolve('/Other'), isNull);
    expect(await tree.resolve('/Albums/Camera/IMG_0001.jpg/more'), isNull);
  });

  test('never resolves a path with dot segments', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);

    expect(await tree.resolve('/Albums/../Albums/Camera'), isNull);
    expect(await tree.resolve('/Albums/./Camera'), isNull);
    expect(await tree.resolve('/../etc/passwd'), isNull);
  });

  test('groups every photo and video by month, the newest month first', () async {
    addAsset('1', 'A.jpg', createdAt: DateTime(2026, 8, 15, 12));
    addAsset('2', 'B.jpg', createdAt: DateTime(2026, 9, 15, 12));
    addAsset('3', 'C.mp4', type: AssetType.video, createdAt: DateTime(2026, 9, 16, 12));
    addAsset('4', 'D.jpg', createdAt: DateTime(2025, 12, 15, 12));

    final months = await tree.resolve('/By month');
    final september = await tree.resolve('/By month/2026-09');

    expect(namesOf(months), ['2026-09', '2026-08', '2025-12']);
    expect(namesOf(september), ['C.mp4', 'B.jpg']);
    expect(await tree.resolve('/By month/2026-13'), isNull);
    expect((await tree.resolve('/By month/2025-12/D.jpg') as PhoneGalleryFile?)?.assetId, '4');
  });

  test('the 360 folder holds the assets found or forced 360', () async {
    addAsset('1', 'PANO.jpg', createdAt: DateTime.utc(2026, 9, 1));
    addAsset('2', 'VID.insv', type: AssetType.video, createdAt: DateTime.utc(2026, 9, 2));
    addAsset('3', 'Flat.jpg', createdAt: DateTime.utc(2026, 9, 3));
    panoramaIds = {'1', '2', 'server-id-of-a-forced-asset'};

    final panoramas = await tree.resolve('/360');

    expect(namesOf(panoramas), ['VID.insv', 'PANO.jpg']);
    expect((await tree.resolve('/360/PANO.jpg') as PhoneGalleryFile?)?.assetId, '1');
  });

  test('serves an edited photo under its name with the extension of the file the platform serves', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset(
      '1',
      'IMG_0001.HEIC',
      createdAt: DateTime.utc(2026, 9, 1),
      albums: ['a1'],
      servedName: 'FullSizeRender.jpg',
    );

    expect(namesOf(await tree.resolve('/Albums/Camera')), ['IMG_0001.jpg']);
    expect(phoneShareFileName('IMG_1.HEIC', 'IMG_1.heic'), 'IMG_1.HEIC');
    expect(phoneShareFileName('noextension', 'render.jpg'), 'noextension.jpg');
    expect(phoneShareFileName('a/b.jpg', 'x'), 'a_b.jpg');
  });

  test('keeps a listing 30 s, then reads the gallery again', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);

    await tree.resolve('/Albums/Camera');
    await tree.resolve('/Albums/Camera/IMG_0001.jpg');
    await tree.resolve('/Albums/Camera');
    expect(gallery.calls, ['albums', 'albumAssets a1']);
    expect(files.infoCalls, hasLength(1));

    now = now.add(const Duration(seconds: 31));
    addAsset('2', 'IMG_0002.jpg', createdAt: DateTime.utc(2026, 9, 2), albums: ['a1']);

    expect(namesOf(await tree.resolve('/Albums/Camera')), ['IMG_0002.jpg', 'IMG_0001.jpg']);
    expect(gallery.calls, ['albums', 'albumAssets a1', 'albums', 'albumAssets a1']);
  });

  test('asks the platform about 500 assets at a time', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Big'));
    for (var i = 0; i < 1203; i++) {
      gallery.add(
        galleryAsset('$i', 'IMG_$i.jpg', createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i))),
        albums: ['a1'],
      );
    }

    final album = await tree.resolve('/Albums/Big');

    expect(files.infoCalls.map((ids) => ids.length), [500, 500, 203]);
    // None of them has a file here
    expect(namesOf(album), isEmpty);
  });

  test('tells the size learned by opening a file when the platform does not tell it', () async {
    files.toldSize = 0;
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);

    expect((await tree.resolve('/Albums/Camera/IMG_0001.jpg') as PhoneGalleryFile?)?.size, isNull);

    tree.rememberSize('1', 4242);
    now = now.add(const Duration(minutes: 1));

    expect((await tree.resolve('/Albums/Camera/IMG_0001.jpg') as PhoneGalleryFile?)?.size, 4242);
  });

  test('a failed listing is not kept', () async {
    gallery.albumList.add(galleryAlbum('a1', 'Camera'));
    addAsset('1', 'IMG_0001.jpg', createdAt: DateTime.utc(2026, 9, 1), albums: ['a1']);
    final failing = PhoneGalleryTree(
      source: gallery,
      files: _FailingOnceFiles(files),
      panoramaIds: () => const {},
      clock: () => now,
    );

    await expectLater(failing.resolve('/Albums/Camera'), throwsA(isA<StateError>()));
    expect(namesOf(await failing.resolve('/Albums/Camera')), ['IMG_0001.jpg']);
  });

  test('sanitizePhoneShareName keeps a name usable as one segment', () {
    expect(sanitizePhoneShareName('Été 2026'), 'Été 2026');
    expect(sanitizePhoneShareName(r'a\b/c'), 'a_b_c');
    expect(sanitizePhoneShareName('  '), '_');
    expect(sanitizePhoneShareName('...'), '_');
    expect(sanitizePhoneShareName('line\nbreak'), 'line_break');
  });
}

class _FailingOnceFiles implements PhoneShareFiles {
  _FailingOnceFiles(this._files);

  final PhoneShareFiles _files;
  var _failed = false;

  @override
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) {
    if (!_failed) {
      _failed = true;
      throw StateError('The platform channel is not ready');
    }
    return _files.fileInfos(assetIds);
  }

  @override
  Future<PhoneShareOpenedFile?> openFile(String assetId) => _files.openFile(assetId);
}
