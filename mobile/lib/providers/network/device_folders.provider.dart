// The folders of this device chosen with "Browse a folder" (On this device, and the Add menu of the Network shares):
// each one picked once in the system picker of Android, kept in a small JSON file of the app with the read grant
// Android gives for it, and browsed as a share (see NetworkSourceType.deviceFolder): every subfolder, the photos and
// videos, the splats on a Meta Quest. Android phones and tablets and the Meta Quest; not iOS, not the computers (they
// have folders of their own), not the TV layout nor a television in this lot.

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DeviceFolders');

/// Where the system picker opens for Browse a folder: the Download folder of the storage of the device, where the
/// files from a browser, a computer or a transfer land. From Android 11 on, the picker offers every folder in it but
/// not Download itself.
const deviceFolderPickerStart = 'Download';

/// Whether "Browse a folder" is offered here: Android phones and tablets and the Meta Quest, not the TV layout, and
/// never a television, whatever its layout setting. Not iOS nor the computers, which have no DocumentTreeApi. Tests
/// replace it.
final deviceFoldersSupportedProvider = Provider.autoDispose<bool>((ref) {
  if (!CurrentPlatform.isAndroid) {
    return false;
  }
  return !ref.watch(tvModeProvider) && !ref.watch(tvDeviceProvider).isTelevision;
}, dependencies: [tvModeProvider, tvDeviceProvider]);

/// The version of Android (Build.VERSION.SDK_INT), null when it cannot be told. Tests replace it.
final androidSdkIntProvider = FutureProvider<int?>((ref) async {
  try {
    return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  } catch (error) {
    _log.fine('Could not read the version of Android: $error');
    return null;
  }
});

/// Whether to say, under "Browse a folder", that Android keeps the Download folder itself and the whole storage out
/// of the picker: from Android 11 (API 30) on, the picker offers every folder inside them, never them
final deviceFolderPickerHintProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (!ref.watch(deviceFoldersSupportedProvider)) {
    return false;
  }
  final sdk = await ref.watch(androidSdkIntProvider.future);
  return sdk != null && sdk >= 30;
}, dependencies: [deviceFoldersSupportedProvider]);

/// The folders of the device chosen before, in the support folder of the app: the store of the folders picked on the
/// DJI drone page, in a file of its own. Tests replace it.
final deviceFolderStoreProvider = Provider<DroneRecentStore>(
  (_) =>
      DroneRecentStore(() async => File(p.join((await getApplicationSupportDirectory()).path, 'device_folders.json'))),
);

/// Gives back the read grant of the picked folder [treeUri], unless the DJI drone page or the device folders still
/// list it: Android keeps one grant per folder for the whole app. Called once the folder left the list that dropped it.
Future<void> releasePickedFolder(Ref ref, String treeUri) async {
  final drone = await ref.read(droneRecentStoreProvider).load();
  final folders = await ref.read(deviceFolderStoreProvider).load();
  if ([...drone, ...folders].any((tree) => tree.treeUri == treeUri)) {
    _log.fine('The grant of a picked folder is kept: another list holds it');
    return;
  }
  try {
    await ref.read(documentTreeApiProvider).release(treeUri);
  } catch (error) {
    _log.fine('Could not give back the grant of a picked folder: $error');
  }
}

class DeviceFoldersState {
  const DeviceFoldersState({this.folders = const [], this.missing = const {}, this.loaded = false});

  /// The folders chosen, in the order they were chosen
  final List<RecentTree> folders;

  /// The tree URIs of those that cannot be read now: moved, deleted, unplugged, or their grant taken back
  final Set<String> missing;

  /// Whether the list chosen before was read
  final bool loaded;

  DeviceFoldersState copyWith({List<RecentTree>? folders, Set<String>? missing, bool? loaded}) => DeviceFoldersState(
    folders: folders ?? this.folders,
    missing: missing ?? this.missing,
    loaded: loaded ?? this.loaded,
  );
}

class DeviceFoldersNotifier extends Notifier<DeviceFoldersState> {
  late Future<void> _ready;

  /// Completes once the folders chosen before were read, registered as sources and checked
  Future<void> get ready => _ready;

  DocumentTreeApi get _api => ref.read(documentTreeApiProvider);

  @override
  DeviceFoldersState build() {
    _ready = _load();
    return const DeviceFoldersState();
  }

  Future<void> _load() async {
    // Not before build returned: the state is set from here
    await Future<void>.value();
    final folders = await ref.read(deviceFolderStoreProvider).load();
    folders.forEach(_register);
    state = state.copyWith(folders: folders, loaded: true);
    await _check();
  }

  /// Opens the system folder picker in [deviceFolderPickerStart] and keeps the folder chosen at the end of the list (once: a folder chosen again
  /// keeps its place, under the names the picker gives now); gives the id of its source, which the browser opens, or
  /// null when the user goes back. Throws when the picker cannot open.
  Future<String?> browse() async {
    final pick = await _api.pickTree(deviceFolderPickerStart);
    if (pick == null) {
      return null;
    }
    await _ready;
    final folder = RecentTree.of(pick, DateTime.now());
    final index = state.folders.indexWhere((tree) => tree.treeUri == pick.treeUri);
    final folders = [...state.folders];
    if (index < 0) {
      folders.add(folder);
    } else {
      folders[index] = folder;
    }
    state = state.copyWith(folders: folders, missing: {...state.missing}..remove(pick.treeUri));
    await ref.read(deviceFolderStoreProvider).save(folders);
    _register(folder);
    _log.info('Folder of the device chosen: ${pick.folderName} (${pick.kind})');
    return deviceFolderSourceId(pick.treeUri);
  }

  /// The id of the source of [folder] when it can be read now, its names brought up to date; null, and the folder
  /// marked as missing, when it cannot. A connection that found the folder gone is closed, so that the browser reads
  /// it again through a new one.
  Future<String?> open(RecentTree folder) async {
    final pick = await _reopen(folder.treeUri);
    if (pick == null) {
      state = state.copyWith(missing: {...state.missing, folder.treeUri});
      return null;
    }
    final updated = RecentTree.of(pick, folder.lastSeen);
    final index = state.folders.indexWhere((tree) => tree.treeUri == folder.treeUri);
    if (index >= 0) {
      final current = state.folders[index];
      final folders = [...state.folders];
      folders[index] = updated;
      state = state.copyWith(folders: folders, missing: {...state.missing}..remove(folder.treeUri));
      if (current.title != pick.title || current.folderName != pick.folderName || current.kind != pick.kind) {
        await ref.read(deviceFolderStoreProvider).save(folders);
      }
    }
    _register(updated);
    final sourceId = deviceFolderSourceId(folder.treeUri);
    final connections = ref.read(networkConnectionsProvider);
    final opened = connections.opened(sourceId);
    if (opened is DocumentTreeFileSystem && opened.isUnplugged) {
      await connections.close(sourceId);
    }
    return sourceId;
  }

  /// Takes [folder] out of the list: its upload stopped, its connection closed, its source gone, its grant given back
  /// unless the DJI drone page lists it too. Nothing on the device changes.
  Future<void> remove(RecentTree folder) async {
    await _ready;
    final folders = state.folders.where((tree) => tree.treeUri != folder.treeUri).toList();
    state = state.copyWith(folders: folders, missing: {...state.missing}..remove(folder.treeUri));
    await ref.read(deviceFolderStoreProvider).save(folders);
    final sourceId = deviceFolderSourceId(folder.treeUri);
    ref.read(networkUploadProvider.notifier).cancelFrom(sourceId);
    await ref.read(networkConnectionsProvider).close(sourceId);
    ref.read(importSourcesProvider.notifier).remove(sourceId);
    await releasePickedFolder(ref, folder.treeUri);
  }

  /// Looks again at which folders can be read, when the list shows
  Future<void> recheck() async {
    await _ready;
    await _check();
  }

  Future<void> _check() async {
    final missing = <String>{};
    for (final folder in state.folders) {
      if (await _reopen(folder.treeUri) == null) {
        missing.add(folder.treeUri);
      }
    }
    state = state.copyWith(missing: missing);
  }

  /// The source of [folder] among the import sources, so that the browser, the viewers and the media bridge find it
  void _register(RecentTree folder) {
    ref
        .read(importSourcesProvider.notifier)
        .put(deviceFolderSource(treeUri: folder.treeUri, folderName: folder.folderName, kind: folder.kind));
  }

  Future<TreePick?> _reopen(String treeUri) async {
    try {
      return await _api.reopen(treeUri);
    } catch (error) {
      _log.fine('Could not open a folder of the device again: $error');
      return null;
    }
  }
}

final deviceFoldersProvider = NotifierProvider<DeviceFoldersNotifier, DeviceFoldersState>(DeviceFoldersNotifier.new);
