import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';

import '../../fixtures/document_tree.fake.dart';

void main() {
  late FakeDocumentTreeApi api;
  late DocumentTreeFileSystem sut;

  const source = NetworkSource(
    id: 'tree:0123456789abcdef',
    type: NetworkSourceType.documentTree,
    name: 'USB drive',
    host: 'usb',
    share: 'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3A',
  );

  Uint8List bytes(int length) => Uint8List.fromList(List.generate(length, (index) => index % 256));

  setUp(() {
    api = FakeDocumentTreeApi(
      {
        '/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG': bytes(300),
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4': bytes(1000),
        '/DCIM/PANORAMA/001_0042/DJI_0001.JPG': bytes(10),
        '/MISC/log.db': bytes(5),
      },
      dates: {'/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG': DateTime.utc(2026, 10, 21, 12, 30)},
      thumbnailPaths: {'/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4'},
    );
    sut = DocumentTreeFileSystem(source, api, unpluggedMessage: () => 'The drone or card was unplugged');
  });

  test('lists a folder as a share, folders first, with paths from the folder picked', () async {
    final root = await sut.list('/');
    expect(root.map((entry) => (entry.path, entry.isDirectory)), [('/DCIM', true), ('/MISC', true)]);
    expect(api.listed, [null], reason: 'the folder picked has no id');

    final folder = await sut.list('/DCIM/DJI_001/');
    expect(folder.map((entry) => entry.path), [
      '/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG',
      '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4',
    ]);
    final photo = folder.first;
    expect(photo.sourceId, source.id);
    expect(photo.size, 300);
    expect(photo.modified, DateTime.utc(2026, 10, 21, 12, 30));
    expect(photo.isImported, isTrue);
    // The folders on the way were listed to learn the id of DJI_001
    expect(api.listed, [null, '/DCIM', '/DCIM/DJI_001']);
  });

  test('reads a file by ranges through the id learned from its folder', () async {
    final read = await sut.readRange('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4', 990, 100);

    expect(read, bytes(1000).sublist(990));
    expect(api.reads.single, ('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4', 990, 100));
    expect(await sut.readRange('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4', 0, 0), isEmpty);
  });

  test('reads more than the bridge reads at once in several reads', () async {
    const size = DocumentTreeFileSystem.maxBridgeRead * 2 + 100;
    api.files['/DCIM/big.MP4'] = bytes(size);
    api.maxRead = DocumentTreeFileSystem.maxBridgeRead;

    final read = await sut.readRange('/DCIM/big.MP4', 50, size);

    expect(read.length, size - 50);
    expect(read.sublist(0, 4), bytes(54).sublist(50));
    expect(api.reads.map((read) => read.$3), [
      DocumentTreeFileSystem.maxBridgeRead,
      DocumentTreeFileSystem.maxBridgeRead,
      100,
    ]);
  });

  test('stats a file and the folder picked', () async {
    final file = await sut.stat('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG');
    expect((file.path, file.size, file.isDirectory), ('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG', 300, false));
    expect((await sut.stat('/')).isDirectory, isTrue);
  });

  test('a path that is not there is not found', () async {
    await expectLater(
      sut.readRange('/DCIM/DJI_001/missing.JPG', 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((error) => error.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('an unplugged drive fails every call at once with the message of the page', () async {
    await sut.list('/DCIM/DJI_001');
    api.unplugged = true;

    await expectLater(
      sut.readRange('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4', 0, 10),
      throwsA(
        isA<NetworkFileSystemException>().having(
          (error) => error.message,
          'message',
          'The drone or card was unplugged',
        ),
      ),
    );
    expect(sut.isUnplugged, isTrue);
    api.unplugged = false;
    final readsBefore = api.reads.length;
    await expectLater(sut.list('/DCIM'), throwsA(isA<NetworkFileSystemException>()));
    expect(api.reads.length, readsBefore, reason: 'no call once unplugged');
    expect(() => sut.checkPlugged(), throwsA(isA<NetworkFileSystemException>()));
  });

  test('a read the device does not answer is given up, the files closed, and the next reads fail at once', () async {
    final stalling = DocumentTreeFileSystem(
      source,
      api,
      stalledMessage: () => 'The drone or card stopped answering',
      readTimeout: const Duration(milliseconds: 50),
    );
    await stalling.list('/DCIM/DJI_001');
    api.stall = Completer<void>();
    const video = '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4';

    await expectLater(
      stalling.readRange(video, 0, 10),
      throwsA(
        isA<NetworkFileSystemException>().having((e) => e.message, 'message', 'The drone or card stopped answering'),
      ),
    );
    expect(api.closed, [source.share], reason: 'closing the files stops the read stuck on the Kotlin side');
    final readsBefore = api.reads.length;
    await expectLater(stalling.readRange(video, 0, 10), throwsA(isA<NetworkFileSystemException>()));
    expect(api.reads.length, readsBefore, reason: 'not queued behind the stuck read');

    // The stuck read ends (the Kotlin side closed its file): the device is read again
    api.stall!.complete();
    api.stall = null;
    await pumpEventQueue();
    expect(await stalling.readRange(video, 0, 10), bytes(10));
    expect(stalling.isUnplugged, isFalse);
  });

  test('a read stopped on the Kotlin side tells that the device stopped answering', () async {
    final stalling = DocumentTreeFileSystem(source, api, stalledMessage: () => 'The drone or card stopped answering');
    await stalling.list('/DCIM/DJI_001');
    api.stall = Completer<void>()..complete();

    await expectLater(
      stalling.readRange('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4', 0, 10),
      throwsA(
        isA<NetworkFileSystemException>().having((e) => e.message, 'message', 'The drone or card stopped answering'),
      ),
    );
  });

  test('tells when a device was still sending its list, and when it reads files from their start only', () async {
    await sut.list('/DCIM/DJI_001');
    expect((sut.hasIncompleteListing, sut.readsFromStartOnly), (false, false));

    api
      ..listComplete = false
      ..seekable = false;
    await sut.list('/DCIM/DJI_001');
    expect((sut.hasIncompleteListing, sut.readsFromStartOnly), (true, true));

    api.listComplete = true;
    await sut.list('/DCIM/DJI_001');
    expect(sut.hasIncompleteListing, isFalse, reason: 'listed whole again');
  });

  test('thumbnails come from the EXIF of a photo, else from the provider, else none', () async {
    await sut.list('/DCIM/DJI_001');
    final video = NetworkEntry(
      sourceId: source.id,
      path: '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4',
      isDirectory: false,
    );
    final photo = NetworkEntry(
      sourceId: source.id,
      path: '/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG',
      isDirectory: false,
    );

    expect(await sut.thumbnail(video, 256), isNotNull, reason: 'the provider makes one');
    expect(await sut.thumbnail(photo, 256), isNull, reason: 'no EXIF thumbnail, none from the provider');
    expect(api.reads.single.$1, photo.path, reason: 'the head of the photo was read for its EXIF');
  });

  test('closes the files of the tree, and gives the document id of a file for the copies', () async {
    expect(
      await sut.documentIdOf('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG'),
      '/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG',
    );
    await sut.close();
    expect(api.closed, [source.share]);
  });
}
