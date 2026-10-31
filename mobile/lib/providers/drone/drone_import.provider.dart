// The DJI drone page: the folder picked in the system picker (a drone, its controller or a card plugged into the phone),
// read as a share through the import sources (see ImportSourcesNotifier and DocumentTreeFileSystem), its files grouped
// for the page (see groupDroneFiles), the folders picked before, the copies into the gallery, and what happens when the
// drone is unplugged or plugged back.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/drone_import_grouping.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/providers/network/device_folders.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DroneImport');

/// The album of the gallery "Keep on the device" copies into, under DCIM
const droneImportAlbum = 'Immuch360 import';

/// Folders kept in the list of the folders picked before
const droneRecentLimit = 5;

/// The bridge to the system picker and the picked folders. Tests replace it.
final documentTreeApiProvider = Provider<DocumentTreeApi>((_) => DocumentTreeApi());

/// Hands the events of the bridge (copy progress, USB plugged or unplugged) to a listener, null to stop. Tests replace
/// it.
final documentTreeEventsSetUpProvider = Provider<void Function(DocumentTreeEvents? events)>(
  (_) =>
      (events) => DocumentTreeEvents.setUp(events),
);

/// A folder picked before, offered again on the page
class RecentTree {
  const RecentTree({
    required this.treeUri,
    required this.title,
    required this.folderName,
    required this.kind,
    required this.lastSeen,
  });

  factory RecentTree.of(TreePick pick, DateTime now) =>
      RecentTree(treeUri: pick.treeUri, title: pick.title, folderName: pick.folderName, kind: pick.kind, lastSeen: now);

  final String treeUri;
  final String title;
  final String folderName;

  /// "usb", "mtp", "internal" or "other", see TreePick.kind
  final String kind;
  final DateTime lastSeen;

  TreePick get pick => TreePick(treeUri: treeUri, title: title, folderName: folderName, kind: kind);

  Map<String, Object> toJson() => {
    'uri': treeUri,
    'title': title,
    'folder': folderName,
    'kind': kind,
    'seen': lastSeen.toUtc().toIso8601String(),
  };

  static RecentTree? fromJson(Object? json) {
    if (json case {
      'uri': final String uri,
      'title': final String title,
      'folder': final String folder,
      'kind': final String kind,
      'seen': final String seen,
    }) {
      final lastSeen = DateTime.tryParse(seen);
      return lastSeen == null
          ? null
          : RecentTree(treeUri: uri, title: title, folderName: folder, kind: kind, lastSeen: lastSeen);
    }
    return null;
  }
}

/// The folders picked before, in a small JSON file of the app (none when [_file] gives null)
class DroneRecentStore {
  const DroneRecentStore(this._file);

  final Future<File?> Function() _file;

  Future<List<RecentTree>> load() async {
    try {
      final file = await _file();
      // ignore: avoid_slow_async_io
      if (file == null || !await file.exists()) {
        return [];
      }
      final json = jsonDecode(await file.readAsString());
      final list = json is Map ? json['trees'] : null;
      return [
        if (list is List)
          for (final item in list)
            if (RecentTree.fromJson(item) case final RecentTree tree) tree,
      ];
    } catch (error, stackTrace) {
      _log.warning('Could not read the folders picked before', error, stackTrace);
      return [];
    }
  }

  Future<void> save(List<RecentTree> trees) async {
    try {
      final file = await _file();
      if (file == null) {
        return;
      }
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode({'trees': trees.map((tree) => tree.toJson()).toList()}), flush: true);
      await temporary.rename(file.path);
    } catch (error, stackTrace) {
      _log.warning('Could not write the folders picked before', error, stackTrace);
    }
  }
}

/// The folders picked before, in the support folder of the app. Tests replace it.
final droneRecentStoreProvider = Provider<DroneRecentStore>(
  (_) => DroneRecentStore(
    () async => File(p.join((await getApplicationSupportDirectory()).path, 'drone_import_recent.json')),
  ),
);

/// Where the page stands
enum DroneImportPhase {
  /// No folder open: plug in and choose
  choosing,

  /// The files of the folder are being listed
  reading,

  /// The files are shown
  ready,

  /// The folder stopped answering: plugged out
  unplugged,
}

/// The copies under way into the gallery: [done] of [total] files, the current one at [bytes] of [fileBytes]
typedef DroneKeepProgress = ({int done, int total, int bytes, int fileBytes});

/// What "Keep on the device" did: [saved] files, of which [inDownloads] went to the Download folder rather than the
/// gallery (the files the Immich server refuses, see DroneImportNotifier.keep)
typedef DroneKeepSummary = ({int saved, int inDownloads, int failed, bool cancelled, String? lastError});

/// The MIME type a file the Immich server refuses is kept as: the gallery would rename it after a video type, so it
/// goes to the Download folder under its own name (see DocumentTreeApi.copyToGallery)
const droneKeepOtherMimeType = 'application/octet-stream';

class DroneImportState {
  const DroneImportState({
    this.recents = const [],
    this.missing = const {},
    this.tree,
    this.sourceId,
    this.phase = DroneImportPhase.choosing,
    this.listing,
    this.urls = const {},
    this.frameUrls = const {},
    this.error,
    this.keeping,
    this.incomplete = false,
    this.readsFromStartOnly = false,
  });

  /// The folders picked before, the latest first, and the URIs of those not plugged in now
  final List<RecentTree> recents;
  final Set<String> missing;

  /// The folder open, and the id of its import source
  final TreePick? tree;
  final String? sourceId;
  final DroneImportPhase phase;
  final DroneImportListing? listing;

  /// The media bridge URLs of the media by path, and of the proxies of the videos by the path of the video
  final Map<String, Uri> urls;
  final Map<String, Uri> frameUrls;

  /// Why the folder could not be read
  final Object? error;
  final DroneKeepProgress? keeping;

  /// Files may be missing from the listing: the device was still sending its list, or a folder could not be listed
  final bool incomplete;

  /// The device sends files from their start only (see NetworkSequentialReads): the videos without proxy get no frame
  final bool readsFromStartOnly;

  DroneImportState copyWith({
    List<RecentTree>? recents,
    Set<String>? missing,
    TreePick? tree,
    String? sourceId,
    DroneImportPhase? phase,
    DroneImportListing? listing,
    Map<String, Uri>? urls,
    Map<String, Uri>? frameUrls,
    Object? error,
    bool clearError = false,
    DroneKeepProgress? keeping,
    bool clearKeeping = false,
    bool? incomplete,
    bool? readsFromStartOnly,
  }) => DroneImportState(
    recents: recents ?? this.recents,
    missing: missing ?? this.missing,
    tree: tree ?? this.tree,
    sourceId: sourceId ?? this.sourceId,
    phase: phase ?? this.phase,
    listing: listing ?? this.listing,
    urls: urls ?? this.urls,
    frameUrls: frameUrls ?? this.frameUrls,
    error: clearError ? null : (error ?? this.error),
    keeping: clearKeeping ? null : (keeping ?? this.keeping),
    incomplete: incomplete ?? this.incomplete,
    readsFromStartOnly: readsFromStartOnly ?? this.readsFromStartOnly,
  );
}

// Folders not gone into: the databases and logs of DJI drones, the system folders of cards and phones
const _skippedFolders = {'misc', 'android', 'lost.dir', 'system volume information', r'$recycle.bin'};

/// The files of the folder picked on [fileSystem]: when it holds DCIM, those of DCIM; at most two folder levels below,
/// so that DCIM/DJI_001 and DCIM/PANORAMA/001_0042 are read; the folders of [_skippedFolders] and those whose name
/// starts with a dot left out. A folder below that cannot be listed is left out, and counted in [skipped], unless the
/// device is gone.
Future<({List<NetworkEntry> files, int skipped})> scanDroneFolder(NetworkFileSystem fileSystem) async {
  final top = await fileSystem.list('/');
  final dcim = top.firstWhereOrNull((entry) => entry.isDirectory && entry.name.toUpperCase() == 'DCIM');
  final files = <NetworkEntry>[];
  var skipped = 0;
  Future<void> walk(List<NetworkEntry> entries, int depth) async {
    for (final entry in entries) {
      if (!entry.isDirectory) {
        files.add(entry);
        continue;
      }
      final name = entry.name.toLowerCase();
      if (depth >= 2 || name.startsWith('.') || _skippedFolders.contains(name)) {
        continue;
      }
      final List<NetworkEntry> children;
      try {
        children = await fileSystem.list(entry.path);
      } on NetworkFileSystemException catch (error) {
        if (fileSystem is DocumentTreeFileSystem && fileSystem.isUnplugged) {
          rethrow;
        }
        _log.warning('Could not list ${entry.path}, left out: ${error.message}');
        skipped++;
        continue;
      }
      await walk(children, depth + 1);
    }
  }

  await walk(dcim == null ? top : await fileSystem.list(dcim.path), 0);
  return (files: files, skipped: skipped);
}

class DroneImportNotifier extends Notifier<DroneImportState> implements DocumentTreeEvents {
  int _generation = 0;
  int _nextCopyId = 0;
  int? _copying;
  bool _keepCancelled = false;

  DocumentTreeApi get _api => ref.read(documentTreeApiProvider);

  /// Whether the page is on screen: the USB events are watched only meanwhile
  bool _pageShown = false;

  @override
  DroneImportState build() {
    final setUpEvents = ref.watch(documentTreeEventsSetUpProvider);
    final api = ref.watch(documentTreeApiProvider);
    setUpEvents(this);
    ref.onDispose(() {
      setUpEvents(null);
      if (_pageShown) {
        unawaited(_quietly(() => api.watchUsb(false)));
      }
    });
    unawaited(_loadRecents());
    return const DroneImportState();
  }

  /// The page opened ([shown]) or closed: the USB devices are watched while it is open, and what changed while it was
  /// closed is looked at again when it opens
  void pageShown(bool shown) {
    if (shown == _pageShown) {
      return;
    }
    _pageShown = shown;
    unawaited(_quietly(() => _api.watchUsb(shown)));
    if (shown && state.recents.isNotEmpty) {
      unawaited(_recheck());
    }
  }

  /// Whether the folder open, or the folders picked before, came or went while the page was closed
  Future<void> _recheck() async {
    final tree = state.tree;
    if (tree == null) {
      await _checkRecents();
      return;
    }
    final answers = await _reopen(tree.treeUri) != null;
    if (answers && state.phase == DroneImportPhase.unplugged) {
      await _onUsbChanged(true);
    } else if (!answers && state.phase != DroneImportPhase.unplugged) {
      await _onUsbChanged(false);
    }
  }

  /// Opens the system picker and reads the folder chosen; nothing when the user goes back
  Future<void> choose() async {
    final TreePick? pick;
    try {
      pick = await _api.pickTree();
    } catch (error, stackTrace) {
      _log.warning('Could not open the folder picker', error, stackTrace);
      state = state.copyWith(error: error);
      return;
    }
    if (pick != null) {
      await _open(pick);
    }
  }

  /// Reads a folder picked before, when it is plugged in; marks it "Not plugged in" otherwise
  Future<void> openRecent(RecentTree recent) async {
    final pick = await _reopen(recent.treeUri);
    if (pick == null) {
      state = state.copyWith(missing: {...state.missing, recent.treeUri});
      return;
    }
    await _open(pick);
  }

  /// Forgets a folder picked before, and gives its grant back unless it is a folder of the device too (see
  /// releasePickedFolder)
  Future<void> forget(RecentTree recent) async {
    final recents = state.recents.where((tree) => tree.treeUri != recent.treeUri).toList();
    state = state.copyWith(recents: recents);
    await ref.read(droneRecentStoreProvider).save(recents);
    await releasePickedFolder(ref, recent.treeUri);
  }

  /// Reads the folder open again
  Future<void> refresh() async {
    final tree = state.tree;
    if (tree == null) {
      await _checkRecents();
      return;
    }
    final pick = await _reopen(tree.treeUri) ?? tree;
    await _open(pick);
  }

  /// Back to the choice of a folder
  Future<void> closeTree() async {
    final sourceId = state.sourceId;
    _generation++;
    state = DroneImportState(recents: state.recents, missing: state.missing);
    if (sourceId != null) {
      await ref.read(networkConnectionsProvider).close(sourceId);
    }
    await _checkRecents();
  }

  Future<void> _open(TreePick pick) async {
    final generation = ++_generation;
    final sourceId = ImportSourcesNotifier.idFor(pick.treeUri);
    final connections = ref.read(networkConnectionsProvider);
    // A folder plugged again is read through a new connection: the ids of an MTP device change with each plug
    await connections.close(sourceId);
    ref
        .read(importSourcesProvider.notifier)
        .put(
          NetworkSource(
            id: sourceId,
            type: NetworkSourceType.documentTree,
            name: pick.title,
            host: pick.kind,
            share: pick.treeUri,
          ),
        );
    final missing = {...state.missing}..remove(pick.treeUri);
    state = pick.treeUri == state.tree?.treeUri
        // Read again: what was shown stays until the new listing comes
        ? state.copyWith(tree: pick, phase: DroneImportPhase.reading, missing: missing, clearError: true)
        : DroneImportState(
            recents: state.recents,
            missing: missing,
            tree: pick,
            sourceId: sourceId,
            phase: DroneImportPhase.reading,
          );
    await _remember(pick);
    try {
      final fileSystem = await connections.fileSystem(sourceId);
      final scan = await scanDroneFolder(fileSystem);
      final listing = groupDroneFiles(scan.files);
      final tree = fileSystem is DocumentTreeFileSystem ? fileSystem : null;
      final urls = <String, Uri>{};
      final frameUrls = <String, Uri>{};
      for (final entry in listing.allMedia) {
        urls[entry.path] = await connections.mediaUrl(sourceId, entry.path);
      }
      for (final media in listing.byPath.values) {
        final proxy = media.proxy;
        if (proxy != null) {
          frameUrls[media.entry.path] = await connections.mediaUrl(sourceId, proxy.path);
        }
      }
      if (generation != _generation) {
        return;
      }
      state = state.copyWith(
        phase: DroneImportPhase.ready,
        listing: listing,
        urls: urls,
        frameUrls: frameUrls,
        incomplete: scan.skipped > 0 || (tree?.hasIncompleteListing ?? false),
        readsFromStartOnly: tree?.readsFromStartOnly ?? false,
      );
      _log.info('${pick.title}: ${listing.allMedia.length} photos and videos in ${listing.days.length} days');
      unawaited(_checkTrash(listing.allMedia));
    } catch (error, stackTrace) {
      if (generation != _generation) {
        return;
      }
      _log.warning('Could not read ${pick.title}', error, stackTrace);
      final gone = await _reopen(pick.treeUri) == null;
      state = state.copyWith(phase: gone ? DroneImportPhase.unplugged : DroneImportPhase.ready, error: error);
    }
  }

  /// Copies [entries] into the gallery, album [droneImportAlbum], one at a time, until [cancelKeep]. The files the
  /// Immich server refuses (see NetworkEntry.isRefusedByServer, a raw 360° video of a DJI camera) go to the Download
  /// folder under their own name: the gallery would rename them after a video type, and the device backup would then
  /// send them to Immich as flat videos.
  Future<DroneKeepSummary> keep(List<NetworkEntry> entries) async {
    final tree = state.tree;
    final sourceId = state.sourceId;
    if (tree == null || sourceId == null || entries.isEmpty || state.keeping != null) {
      return (saved: 0, inDownloads: 0, failed: 0, cancelled: false, lastError: null);
    }
    _keepCancelled = false;
    var saved = 0;
    var inDownloads = 0;
    var failed = 0;
    String? lastError;
    state = state.copyWith(keeping: (done: 0, total: entries.length, bytes: 0, fileBytes: entries.first.size ?? 0));
    try {
      final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
      if (fileSystem is! DocumentTreeFileSystem) {
        throw const NetworkFileSystemException('Not a picked folder');
      }
      for (final (index, entry) in entries.indexed) {
        if (_keepCancelled) {
          break;
        }
        state = state.copyWith(keeping: (done: index, total: entries.length, bytes: 0, fileBytes: entry.size ?? 0));
        final copyId = ++_nextCopyId;
        _copying = copyId;
        try {
          fileSystem.checkPlugged();
          final documentId = await fileSystem.documentIdOf(entry.path);
          await _api.copyToGallery(
            copyId,
            tree.treeUri,
            documentId,
            entry.name,
            entry.isRefusedByServer ? droneKeepOtherMimeType : entry.guessedMimeType,
            droneImportAlbum,
            droneTakenAt(entry).millisecondsSinceEpoch,
          );
          saved++;
          if (entry.isRefusedByServer) {
            inDownloads++;
          }
        } on PlatformException catch (error) {
          if (error.code == 'cancelled') {
            break;
          }
          failed++;
          lastError = error.message ?? error.code;
          _log.warning('Could not keep ${entry.name}: ${error.code} ${error.message}');
          if (error.code == 'unplugged') {
            break;
          }
        } on NetworkFileSystemException catch (error) {
          failed++;
          lastError = error.message;
          break;
        }
      }
    } catch (error, stackTrace) {
      _log.warning('Could not keep the files on the device', error, stackTrace);
      lastError = error.toString();
    } finally {
      _copying = null;
      state = state.copyWith(clearKeeping: true);
    }
    return (saved: saved, inDownloads: inDownloads, failed: failed, cancelled: _keepCancelled, lastError: lastError);
  }

  /// Stops the copies into the gallery: the file being copied is not kept
  void cancelKeep() {
    _keepCancelled = true;
    final copying = _copying;
    if (copying != null) {
      unawaited(_quietly(() => _api.cancelCopy(copying)));
    }
  }

  @override
  void onCopyProgress(int copyId, int bytes, int total) {
    final keeping = state.keeping;
    if (copyId != _copying || keeping == null) {
      return;
    }
    state = state.copyWith(
      keeping: (
        done: keeping.done,
        total: keeping.total,
        bytes: bytes,
        fileBytes: total > 0 ? total : keeping.fileBytes,
      ),
    );
  }

  @override
  void onUsbChanged(bool attached) {
    unawaited(_onUsbChanged(attached));
  }

  Future<void> _onUsbChanged(bool attached) async {
    final tree = state.tree;
    if (!attached) {
      if (tree == null || state.phase == DroneImportPhase.unplugged) {
        return;
      }
      if (await _reopen(tree.treeUri) != null) {
        // Another device went away
        return;
      }
      _log.info('${tree.title} was unplugged');
      _generation++;
      final sourceId = state.sourceId;
      if (sourceId != null) {
        // Only an upload from this folder: one from a share goes on
        ref.read(networkUploadProvider.notifier).cancelFrom(sourceId);
      }
      cancelKeep();
      state = state.copyWith(phase: DroneImportPhase.unplugged);
      if (sourceId != null) {
        await ref.read(networkConnectionsProvider).close(sourceId);
      }
      return;
    }
    if (tree != null && state.phase == DroneImportPhase.unplugged) {
      // The volume of a USB drive comes a moment after the device
      final pick = await _reopen(tree.treeUri);
      if (pick != null) {
        await _open(pick);
      }
      return;
    }
    await _checkRecents();
  }

  Future<void> _loadRecents() async {
    final recents = await ref.read(droneRecentStoreProvider).load();
    state = state.copyWith(recents: recents);
    await _checkRecents();
  }

  /// Which folders picked before are plugged in now
  Future<void> _checkRecents() async {
    final missing = <String>{};
    for (final recent in state.recents) {
      if (await _reopen(recent.treeUri) == null) {
        missing.add(recent.treeUri);
      }
    }
    state = state.copyWith(missing: missing);
  }

  Future<void> _remember(TreePick pick) async {
    final all = [RecentTree.of(pick, DateTime.now()), ...state.recents.where((tree) => tree.treeUri != pick.treeUri)];
    final recents = all.take(droneRecentLimit).toList();
    state = state.copyWith(recents: recents);
    await ref.read(droneRecentStoreProvider).save(recents);
    // The grants of the folders dropped from the list are given back: Android keeps a limited number per app. Not
    // those of the folders of the device chosen in On this device, which share them.
    for (final dropped in all.skip(droneRecentLimit)) {
      await releasePickedFolder(ref, dropped.treeUri);
    }
  }

  /// The files sent before whose asset was put in the Immich trash since lose their cloud mark (see
  /// NetworkUploadRecordsNotifier.checkTrash)
  Future<void> _checkTrash(Iterable<NetworkEntry> entries) async {
    try {
      await ref.read(networkUploadRecordsProvider.notifier).checkTrash(entries);
    } catch (error) {
      _log.info('Could not look at the trash of the server for the files sent before: $error');
    }
  }

  Future<TreePick?> _reopen(String treeUri) async {
    try {
      return await _api.reopen(treeUri);
    } catch (error) {
      _log.fine('Could not open $treeUri again: $error');
      return null;
    }
  }

  static Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } catch (error) {
      _log.fine('A call of the folder bridge failed: $error');
    }
  }
}

final droneImportProvider = NotifierProvider<DroneImportNotifier, DroneImportState>(DroneImportNotifier.new);
