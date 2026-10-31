import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/services/folder_contents.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';

import '../../fixtures/document_tree.fake.dart';

const _treeUri = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FQuest';

void main() {
  late FakeDocumentTreeApi api;
  late NetworkSource source;
  late DocumentTreeFileSystem sut;

  Uint8List bytes(int length) => Uint8List.fromList(List.generate(length, (index) => index % 256));
  Uint8List fixture(String name) => File('test/fixtures/splat/$name').readAsBytesSync();

  setUp(() {
    api = FakeDocumentTreeApi(
      {
        '/beach.jpg': bytes(300),
        '/trip.mp4': bytes(1000),
        '/notes.txt': bytes(10),
        '/.nomedia': bytes(0),
        '/.pending-1761900000-sunset.jpg': bytes(10),
        '/.thumbnails/beach.jpg': bytes(10),
        '/Holidays/2026/pano.insp': bytes(40),
        '/Holidays/2026/ride.insv': bytes(50),
        '/Holidays/2026/ride.lrv': bytes(5),
        '/Holidays/raw.dng': bytes(20),
        '/Immuch360-splats/cash.spz': fixture('cash_register_head.spz'),
        '/Immuch360-splats/axes.ply': fixture('axes.ply'),
        '/Immuch360-splats/cube.ply': fixture('mesh_cube.ply'),
      },
      treeUri: _treeUri,
      title: 'Internal shared storage',
      kind: 'internal',
      emptyFolders: {'/Empty'},
    );
    source = deviceFolderSource(treeUri: _treeUri, folderName: 'Quest', kind: 'internal');
    sut = DocumentTreeFileSystem.deviceFolder(source, api);
  });

  group('the source of a folder of the device', () {
    test('a folder source of its own type, in memory only, under an id of its own', () {
      expect(source.type, NetworkSourceType.deviceFolder);
      expect(source.type.isStored, isFalse, reason: 'kept in the list of the device folders, not with the shares');
      expect(source.type.keepsSideFiles, isTrue);
      expect(source.name, 'Quest');
      expect(source.host, 'internal');
      expect(source.share, _treeUri);
      expect(source.rootPath, '/');
      expect(source.id, deviceFolderSourceId(_treeUri));
      expect(source.id, startsWith(NetworkEntry.importSourcePrefix), reason: 'read without a password, never stored');
      expect(deviceFolderSourceId(_treeUri), deviceFolderSourceId(_treeUri), reason: 'the same in every session');
      expect(
        deviceFolderSourceId(_treeUri),
        isNot(ImportSourcesNotifier.idFor(_treeUri)),
        reason: 'apart from the source the DJI drone page makes of the same folder',
      );
      expect(deviceFolderSourceId('$_treeUri%2FOther'), isNot(source.id));
    });

    test('tells where a folder of the storage is, and nothing for a device that numbers its folders', () {
      expect(deviceFolderPath(_treeUri), 'Download/Quest');
      expect(
        deviceFolderPath(
          'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FImmuch360-splats%2FSamples',
        ),
        'Download/Immuch360-splats/Samples',
      );
      expect(deviceFolderPath('content://com.android.externalstorage.documents/tree/1A2B-3C4D%3ADCIM'), 'DCIM');
      expect(deviceFolderPath('content://com.android.externalstorage.documents/tree/1A2B-3C4D%3A'), '');
      expect(deviceFolderPath('content://com.android.mtp.documents/tree/65537'), isNull);
      expect(deviceFolderPath('not a uri'), isNull);
    });
  });

  group('listing', () {
    test('every subfolder, the empty ones and those without media included, then its photos and videos', () async {
      final contents = FolderContents.of(await sut.list('/'));

      expect(contents.folders.map((entry) => entry.name), ['Empty', 'Holidays', 'Immuch360-splats']);
      expect(contents.media.map((entry) => entry.name), ['beach.jpg', 'trip.mp4']);
      expect(contents.splatCandidates, isEmpty);
      expect(contents.isEmpty, isFalse);
      expect(api.listed, [null], reason: 'the folder chosen is listed in one query');
    });

    test('goes deeper, one folder at a time, with the paths from the folder chosen', () async {
      final holidays = FolderContents.of(await sut.list('/Holidays'));
      expect(holidays.folders.map((entry) => entry.path), ['/Holidays/2026']);
      expect(holidays.media.map((entry) => entry.path), ['/Holidays/raw.dng']);

      final year = FolderContents.of(await sut.list('/Holidays/2026'));
      expect(year.folders, isEmpty);
      expect(year.media.map((entry) => (entry.name, entry.isImage, entry.isVideo)), [
        ('pano.insp', true, false),
        ('ride.insv', false, true),
      ], reason: 'the files of 360° cameras are media, their low resolution proxies are not');

      final empty = FolderContents.of(await sut.list('/Empty'));
      expect(empty.isEmpty, isTrue);
    });

    test('leaves out the hidden entries: .nomedia, the files Android is still writing, .thumbnails', () async {
      final entries = await sut.list('/');
      final contents = FolderContents.of(entries);

      expect(entries.map((entry) => entry.name), contains('.thumbnails'), reason: 'the device lists them');
      final shown = [...contents.folders, ...contents.media].map((entry) => entry.name);
      expect(shown.where((name) => name.startsWith('.')), isEmpty);
      expect(shown, isNot(contains('notes.txt')), reason: 'files of other kinds are left out');
      expect(isHiddenFolderEntry(entries.firstWhere((entry) => entry.name == '.nomedia')), isTrue);
      expect(isHiddenFolderEntry(entries.firstWhere((entry) => entry.name == 'beach.jpg')), isFalse);
    });

    test('the .spz and .ply files are the splat candidates, and their head tells a splat from a mesh', () async {
      final contents = FolderContents.of(await sut.list('/Immuch360-splats'));
      expect(contents.media, isEmpty);
      expect(contents.splatCandidates.map((entry) => entry.name), ['axes.ply', 'cash.spz', 'cube.ply']);
      expect(contents.isEmpty, isFalse, reason: 'a folder of splats is not empty');

      Future<SplatProbe> probe(NetworkEntry entry) async =>
          probeSplatHead(await sut.readRange(entry.path, 0, splatHeadBytes), entry.size!);
      final byName = {for (final entry in contents.splatCandidates) entry.name: await probe(entry)};
      expect(byName['cash.spz'], isA<SplatHead>().having((head) => head.gaussians, 'gaussians', 47819));
      expect(byName['axes.ply'], isA<SplatHead>().having((head) => head.gaussians, 'gaussians', 686));
      expect(byName['cube.ply'], isNot(isA<SplatHead>()), reason: 'a mesh is no splat');
    });
  });

  group('its files', () {
    test('are known by their name and size, as those of a drone or a card, and read by ranges', () async {
      final beach = (await sut.list('/')).firstWhere((entry) => entry.name == 'beach.jpg');
      expect(beach.sourceId, source.id);
      expect(beach.isImported, isTrue);
      expect(UploadRecordStore.keyOf(beach), contains('"import"'));

      final read = await sut.readRange('/trip.mp4', 990, 100);
      expect(read, bytes(1000).sublist(990));
      expect((await sut.stat('/Holidays/2026/ride.insv')).size, 50);
    });

    test('a folder gone is told in the words of a folder of the device, not those of a drone', () async {
      api.unplugged = true;

      await expectLater(
        sut.list('/'),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (error) => error.message,
            'message',
            allOf(
              StaticTranslations.instance.device_folder_gone,
              isNot(StaticTranslations.instance.dji_import_unplugged),
            ),
          ),
        ),
      );
      expect(sut.isUnplugged, isTrue);
    });

    test('a folder that stops answering is told in the words of a folder of the device', () async {
      final stall = api.stall = Completer<void>();
      final read = sut.readRange('/trip.mp4', 0, 10);
      await pumpEventQueue();
      stall.complete();

      await expectLater(
        read,
        throwsA(
          isA<NetworkFileSystemException>().having(
            (error) => error.message,
            'message',
            allOf(
              StaticTranslations.instance.device_folder_not_answering,
              isNot(StaticTranslations.instance.dji_import_not_answering),
            ),
          ),
        ),
      );
    });
  });
}
