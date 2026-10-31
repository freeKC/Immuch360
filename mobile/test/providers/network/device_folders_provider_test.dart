import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/device_folders.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';

import '../../fixtures/document_tree.fake.dart';
import 'fakes.dart';

const _download = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FQuest';
const _splats = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FImmuch360-splats';
const _usb = 'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3ADCIM';

TreePick _pick(
  String treeUri,
  String folderName, {
  String title = 'Internal shared storage',
  String kind = 'internal',
}) => TreePick(treeUri: treeUri, title: title, folderName: folderName, kind: kind);

/// The system picker and the grants of the picked folders: the picker gives the answers of [picks] in turn (null: the
/// user went back) or throws [pickError]; a folder answers while it is in [reachable]
class _PickerApi extends FakeDocumentTreeApi {
  _PickerApi() : super({'/beach.jpg': Uint8List(10), '/Sub/ride.mp4': Uint8List(20)}, treeUri: _download);

  final picks = <TreePick?>[];
  Exception? pickError;
  int pickCalls = 0;
  final reachable = <String>{};
  final known = <String, TreePick>{};

  @override
  Future<TreePick?> pickTree(String? startFolder) async {
    pickCalls++;
    pickStarts.add(startFolder);
    final error = pickError;
    if (error != null) {
      throw error;
    }
    final pick = picks.removeAt(0);
    if (pick != null) {
      known[pick.treeUri] = pick;
      reachable.add(pick.treeUri);
    }
    return pick;
  }

  @override
  Future<TreePick?> reopen(String treeUri) async => reachable.contains(treeUri) ? known[treeUri] : null;
}

/// A list of picked folders in memory, which counts its saves
class _MemoryStore extends DroneRecentStore {
  _MemoryStore([List<RecentTree> trees = const []]) : trees = [...trees], super(() async => null);

  List<RecentTree> trees;
  int saves = 0;

  @override
  Future<List<RecentTree>> load() async => trees;

  @override
  Future<void> save(List<RecentTree> trees) async {
    saves++;
    this.trees = trees;
  }
}

void main() {
  late _PickerApi api;
  late _MemoryStore folders;
  late _MemoryStore drone;
  late FakeMediaBridge bridge;
  final chosenAt = DateTime.utc(2026, 10, 31, 8);

  RecentTree tree(String treeUri, String folderName) => RecentTree.of(_pick(treeUri, folderName), chosenAt);

  setUp(() {
    api = _PickerApi();
    folders = _MemoryStore();
    drone = _MemoryStore();
    bridge = FakeMediaBridge();
  });

  ProviderContainer container({List<Override> overrides = const []}) {
    final container = ProviderContainer(
      overrides: [
        ...overrides,
        documentTreeApiProvider.overrideWithValue(api),
        documentTreeEventsSetUpProvider.overrideWithValue((_) {}),
        deviceFolderStoreProvider.overrideWithValue(folders),
        droneRecentStoreProvider.overrideWithValue(drone),
        mediaBridgeProvider.overrideWithValue(bridge),
        hasServerProvider.overrideWithValue(true),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.deviceFolder: (source, _) async => DocumentTreeFileSystem.deviceFolder(source, api),
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The device folders once the list chosen before is read and checked
  Future<DeviceFoldersState> loaded(ProviderContainer container) async {
    container.read(deviceFoldersProvider);
    await container.read(deviceFoldersProvider.notifier).ready;
    return container.read(deviceFoldersProvider);
  }

  group('the folders chosen before', () {
    test('come back in their order, each a source of the browser, and say which cannot be read now', () async {
      folders.trees = [tree(_download, 'Quest'), tree(_usb, 'DCIM')];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..reachable.add(_download);
      final c = container();

      final state = await loaded(c);

      expect(state.loaded, isTrue);
      expect(state.folders.map((folder) => folder.treeUri), [_download, _usb]);
      expect(state.missing, {_usb});
      final sources = c.read(importSourcesProvider);
      expect(sources[deviceFolderSourceId(_download)]?.type, NetworkSourceType.deviceFolder);
      expect(sources[deviceFolderSourceId(_download)]?.name, 'Quest');
      expect(sources[deviceFolderSourceId(_usb)]?.name, 'DCIM', reason: 'its page tells it cannot be read');
      expect(c.read(networkSourceProvider(deviceFolderSourceId(_download)))?.share, _download);
    });

    test('none: an empty list, ready at once', () async {
      final state = await loaded(container());

      expect(state.loaded, isTrue);
      expect(state.folders, isEmpty);
      expect(api.pickCalls, 0);
    });
  });

  group('Browse a folder', () {
    test('keeps the folder chosen at the end of the list and gives the source the browser opens', () async {
      folders.trees = [tree(_download, 'Quest')];
      api.picks.add(_pick(_splats, 'Immuch360-splats'));
      final c = container();
      await loaded(c);

      final sourceId = await c.read(deviceFoldersProvider.notifier).browse();

      expect(sourceId, deviceFolderSourceId(_splats));
      expect(api.pickStarts, ['Download'], reason: 'the picker opens in the Download folder of the device');
      final state = c.read(deviceFoldersProvider);
      expect(state.folders.map((folder) => folder.folderName), ['Quest', 'Immuch360-splats']);
      expect(folders.trees.map((folder) => folder.treeUri), [_download, _splats], reason: 'kept for the next start');
      final source = c.read(networkSourceProvider(sourceId!))!;
      expect(source.type, NetworkSourceType.deviceFolder);
      expect(source.name, 'Immuch360-splats');
      expect(source.share, _splats);
      final listing = await (await c.read(networkConnectionsProvider).fileSystem(sourceId)).list('/');
      expect(listing.map((entry) => entry.name), ['Sub', 'beach.jpg'], reason: 'read as a share');
    });

    test('back from the picker: nothing kept, nothing to open', () async {
      api.picks.add(null);
      final c = container();
      await loaded(c);

      expect(await c.read(deviceFoldersProvider.notifier).browse(), isNull);

      expect(c.read(deviceFoldersProvider).folders, isEmpty);
      expect(folders.saves, 0);
    });

    test('the same folder chosen again stays once, at its place, under the names the picker gives now', () async {
      folders.trees = [tree(_download, 'Old name'), tree(_usb, 'DCIM')];
      api.picks.add(_pick(_download, 'Quest', title: 'Quest 3'));
      final c = container();
      await loaded(c);

      expect(await c.read(deviceFoldersProvider.notifier).browse(), deviceFolderSourceId(_download));

      final state = c.read(deviceFoldersProvider);
      expect(state.folders.map((folder) => (folder.folderName, folder.title)), [
        ('Quest', 'Quest 3'),
        ('DCIM', 'Internal shared storage'),
      ]);
      expect(state.missing, {_usb});
    });

    test('a picker that cannot open: the error goes to the page, nothing kept', () async {
      api.pickError = PlatformException(code: 'no_picker', message: 'This device has no folder picker');
      final c = container();
      await loaded(c);

      await expectLater(c.read(deviceFoldersProvider.notifier).browse(), throwsA(isA<PlatformException>()));
      expect(c.read(deviceFoldersProvider).folders, isEmpty);
    });
  });

  group('opening a folder chosen before', () {
    test('gives its source when it can be read, and tells it when it cannot', () async {
      folders.trees = [tree(_download, 'Quest'), tree(_usb, 'DCIM')];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..known[_usb] = _pick(_usb, 'DCIM', title: 'SanDisk', kind: 'usb')
        ..reachable.add(_download);
      final c = container();
      final notifier = c.read(deviceFoldersProvider.notifier);
      final state = await loaded(c);

      expect(await notifier.open(state.folders.first), deviceFolderSourceId(_download));
      expect(await notifier.open(state.folders.last), isNull);
      expect(c.read(deviceFoldersProvider).missing, {_usb});

      api.reachable.add(_usb);
      expect(await notifier.open(state.folders.last), deviceFolderSourceId(_usb));
      expect(c.read(deviceFoldersProvider).missing, isEmpty);
      expect(c.read(deviceFoldersProvider).folders.last.title, 'SanDisk', reason: 'the name the system gives now');
    });

    test('reads a folder found gone again through a new connection once it answers', () async {
      folders.trees = [tree(_download, 'Quest')];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..reachable.add(_download);
      final c = container();
      final state = await loaded(c);
      final sourceId = deviceFolderSourceId(_download);
      final connections = c.read(networkConnectionsProvider);
      final first = await connections.fileSystem(sourceId) as DocumentTreeFileSystem;
      api.unplugged = true;
      await expectLater(first.list('/'), throwsA(anything));
      expect(first.isUnplugged, isTrue);

      api.unplugged = false;
      expect(await c.read(deviceFoldersProvider.notifier).open(state.folders.single), sourceId);

      final second = await connections.fileSystem(sourceId);
      expect(second, isNot(same(first)));
      expect((await second.list('/')).map((entry) => entry.name), ['Sub', 'beach.jpg']);
    });

    test('looks again at which folders can be read', () async {
      folders.trees = [tree(_download, 'Quest')];
      api.known[_download] = _pick(_download, 'Quest');
      final c = container();
      expect((await loaded(c)).missing, {_download});

      api.reachable.add(_download);
      await c.read(deviceFoldersProvider.notifier).recheck();

      expect(c.read(deviceFoldersProvider).missing, isEmpty);
    });
  });

  group('removing a folder', () {
    test('takes it out of the list and of the sources, closes its connection and gives its grant back', () async {
      folders.trees = [tree(_download, 'Quest'), tree(_usb, 'DCIM')];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..reachable.add(_download);
      final c = container();
      final state = await loaded(c);
      final sourceId = deviceFolderSourceId(_download);
      await c.read(networkConnectionsProvider).fileSystem(sourceId);

      await c.read(deviceFoldersProvider.notifier).remove(state.folders.first);

      expect(c.read(deviceFoldersProvider).folders.map((folder) => folder.treeUri), [_usb]);
      expect(folders.trees.map((folder) => folder.treeUri), [_usb]);
      expect(c.read(importSourcesProvider).containsKey(sourceId), isFalse);
      expect(bridge.unregistered, [sourceId]);
      expect(api.released, [_download]);
    });

    test('keeps the grant of a folder the DJI drone page still lists', () async {
      folders.trees = [tree(_usb, 'DCIM')];
      drone.trees = [tree(_usb, 'DCIM')];
      final c = container();
      final state = await loaded(c);

      await c.read(deviceFoldersProvider.notifier).remove(state.folders.single);

      expect(c.read(deviceFoldersProvider).folders, isEmpty);
      expect(api.released, isEmpty, reason: 'one grant per folder for the whole app');
    });

    test('the DJI drone page keeps the grant of a folder of the device when it forgets it', () async {
      folders.trees = [tree(_usb, 'DCIM')];
      drone.trees = [tree(_usb, 'DCIM'), tree(_download, 'Quest')];
      final c = container();
      c.read(droneImportProvider);
      await pumpEventQueue();
      final notifier = c.read(droneImportProvider.notifier);

      await notifier.forget(drone.trees.first);
      await notifier.forget(drone.trees.first);

      expect(api.released, [_download], reason: 'the folder of the device keeps its grant');
    });
  });

  group('where it is offered', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    bool supported({
      TargetPlatform platform = TargetPlatform.android,
      bool tvMode = false,
      bool television = false,
      bool horizonOs = false,
    }) {
      debugDefaultTargetPlatformOverride = platform;
      final c = ProviderContainer(
        overrides: [
          tvModeProvider.overrideWithValue(tvMode),
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: television, isLowRamDevice: false)),
          isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        ],
      );
      addTearDown(c.dispose);
      return c.read(deviceFoldersSupportedProvider);
    }

    test('on Android phones and tablets, and on a Meta Quest', () {
      expect(supported(), isTrue);
      expect(supported(horizonOs: true), isTrue);
    });

    test('not on a TV, in the TV layout, nor on iOS and the computers', () {
      expect(supported(tvMode: true), isFalse);
      expect(supported(television: true), isFalse);
      for (final platform in [TargetPlatform.iOS, TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
        expect(supported(platform: platform), isFalse, reason: platform.name);
      }
    });

    test('says that Android keeps the Download folder itself out of the picker from Android 11 on', () async {
      Future<bool> hint(int? sdk) async {
        final c = ProviderContainer(
          overrides: [
            deviceFoldersSupportedProvider.overrideWithValue(true),
            androidSdkIntProvider.overrideWith((ref) async => sdk),
          ],
        );
        addTearDown(c.dispose);
        return c.read(deviceFolderPickerHintProvider.future);
      }

      expect(await hint(29), isFalse);
      expect(await hint(30), isTrue);
      expect(await hint(34), isTrue);
      expect(await hint(null), isFalse);
    });
  });
}
