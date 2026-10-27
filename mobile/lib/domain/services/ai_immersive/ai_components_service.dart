// The AI components on this device (design-final 2026-10-26, section 2.2), shared by the computers and the Quest:
// which are installed, their download when the user asks for it (never otherwise), the size of each file checked at
// each load (the SHA-256 is checked once, at the download), removal, and installed.json.
//
// The folder (aiComponentsFolderProvider) holds runtime/, models/, licenses/ (the licence of each component, copied at
// its installation, and the notices of the libraries built into ONNX Runtime, downloaded with it), tmp/ (the .part
// files, kept to resume a download) and installed.json (version, size, SHA-256, date and source of each component,
// and the files whose deletion waits for the next start). Windows does not delete a DLL that is loaded: removing ONNX
// Runtime after a conversion notes the file, and the pass of the next start (freePendingAtStart, run by the desktop
// start before anything loads a component) deletes it. A removal is refused while a conversion runs (inUse).
//
// installed.json and the memory of the service say the same thing: an entry is kept only once written, and a removal
// is written before any file goes (the file noted for the next start meanwhile), so that a removal that cannot be
// written changes nothing and installed.json never gives as installed a file that is gone. A write that failed does
// not stop the next one.
//
// Phases 2 and 3 (design-final 2026-10-27, section 7.1): an archive (an engine of several files) is unpacked into
// engines/<id>/, each file checked against the catalogue (ai_component_archive.dart), and engines/ is one of the
// folders Remove all empties. The free space of the drive is read before the first byte of an installation (a reader
// given by the computers, none on the Quest): what the components take plus 10 %, 1 GiB at least.
//
// "Move the AI components" (section 7.4): every installed file is copied into the new folder and checked by its sum,
// the new installed.json written there, the new folder kept by the caller (desktop_ai.json), and only then the folders
// of the app in the old one are emptied. A file the system holds (a loaded DLL) stays, and the start pass of the next
// start, which reads the new folder, empties what is left of the old one (movedFrom in installed.json). Refused while a
// conversion or a download runs, into a folder that is not empty, and when the drive cannot take the copies.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_archive.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AiComponentsService');

/// The free space of the drive of a folder, and the name of the drive
class AiFreeSpace {
  const AiFreeSpace({required this.free, required this.volume, this.total});

  final int free;
  final int? total;
  final String volume;
}

/// Reads the free space of the drive of a folder that may not exist yet; null when it cannot
typedef AiFreeSpaceReader = Future<AiFreeSpace?> Function(Directory folder);

/// The space asked to install components that take [bytes]: those bytes and a margin of 10 %, 1 GiB at least
int aiSpaceNeeded(int bytes) => bytes <= 0 ? 0 : bytes + max(bytes ~/ 10, 1024 * 1024 * 1024);

/// The name of the folder of the components, in the folder of the app that holds it
const aiComponentsFolderName = 'ai-components';

enum AiComponentState {
  notInstalled,
  downloading,
  installed,

  /// Installed, but its file is gone or no longer has its size: download it again
  damaged,

  /// Removed, but the system keeps its file until the app starts again (a loaded DLL on Windows)
  removedNextStart,
}

/// What the screens show of a component
class AiComponentStatus {
  const AiComponentStatus(this.state, {this.received = 0, this.total, this.failure});

  final AiComponentState state;

  /// While downloading: the bytes received out of [total] (null when unknown)
  final int received;
  final int? total;

  /// Why the last download failed, until the next one starts
  final AiDownloadException? failure;
}

enum AiRemoveOutcome {
  removed,

  /// The space comes back at the next start
  nextStart,

  /// A conversion runs: nothing was removed
  busy,

  /// installed.json could not be written (full disk, a file held by another program): nothing was removed
  writeFailed,
}

enum AiMoveOutcome {
  /// Moved, nothing left in the old folder
  moved,

  /// Moved; a file the system holds in the old folder goes at the next start
  movedNextStart,

  /// A conversion or a download runs: nothing was moved
  busy,

  /// The new folder holds files already, or is inside the old one
  notEmpty,

  /// The new folder is the one in use
  same,

  /// The drive of the new folder cannot take the copies
  notEnoughSpace,

  /// A copy failed or did not have its sum, or the new folder could not be kept: the copies are gone, the old folder
  /// is used as before
  failed,
}

/// What a move did, with what the drive lacks or why it failed
class AiMoveResult {
  const AiMoveResult(this.outcome, {this.shortage, this.detail});

  final AiMoveOutcome outcome;
  final AiSpaceShortage? shortage;

  /// Why it failed, in English
  final String? detail;
}

/// What the removal of a group of features did, and the shared components it left to the other installed groups
class AiGroupRemoval {
  const AiGroupRemoval(this.outcome, this.kept);

  final AiRemoveOutcome outcome;
  final List<AiComponent> kept;
}

/// See the top of this file
class AiComponentsService extends ChangeNotifier {
  AiComponentsService({
    required this._folder,
    AiComponentDownloader? downloader,
    this.catalogue = aiComponents,
    bool Function()? inUse,
    DateTime Function()? now,
    @visibleForTesting Future<void> Function(FileSystemEntity entity)? delete,
    this._setExecutable = setExecutableBit,
    this.freeSpace,
  }) : _downloader = downloader ?? AiComponentDownloader(),
       inUse = inUse ?? _never,
       _now = now ?? DateTime.now,
       _delete = delete ?? _deleteEntity;

  final Future<Directory> Function() _folder;
  final AiComponentDownloader _downloader;
  final List<AiComponent> catalogue;
  final DateTime Function() _now;
  final Future<void> Function(FileSystemEntity entity) _delete;
  final AiSetExecutable _setExecutable;

  /// Reads the free space of the drive of the components; null where it is not checked (the Quest)
  final AiFreeSpaceReader? freeSpace;

  /// Whether a conversion runs, set by the engine: removal waits for its end
  bool Function() inUse;

  static bool _never() => false;

  /// A link goes as a link, never what it leads to
  static Future<void> _deleteEntity(FileSystemEntity entity) =>
      entity is Link ? entity.delete() : entity.delete(recursive: true);

  static const installedFileName = 'installed.json';
  static const _tmp = 'tmp';
  static const _licenses = 'licenses';

  /// The folders of the app in the folder of the components: Remove all touches nothing else, but installed.json
  static const _ownFolders = ['runtime', 'models', 'engines', _licenses, _tmp];

  /// The source written in installed.json for a file that was already in place with the right sum
  static const alreadyOnDisk = 'already on disk';

  Directory? _root;
  _Installed _installed = _Installed();
  Future<void>? _loaded;
  final _statuses = <String, AiComponentStatus>{};
  final _installs = <String, Future<void>>{};
  final _cancels = <String, AiDownloadCancel>{};
  Future<void> _saving = Future.value();

  /// The bytes to download for [components], from the catalogue, their notices included
  static int downloadBytesOf(Iterable<AiComponent> components) =>
      components.fold(0, (sum, component) => sum + (component.bytesToDownload ?? 0) + (component.notices?.size ?? 0));

  /// The space [components] take once installed, from the catalogue, their notices included (the files of an
  /// archive, not the archive)
  static int diskBytesOf(Iterable<AiComponent> components) =>
      components.fold(0, (sum, component) => sum + (component.installedSize ?? 0) + (component.notices?.size ?? 0));

  static Future<void>? _startPass;

  /// The pass of the start: deletes the files noted for the next start, once per process, before anything loads a
  /// component. The services wait for it before they read installed.json.
  static Future<void> freePendingAtStart(Future<Directory> Function() folder) => _startPass ??= () async {
    try {
      final root = await folder();
      final installed = await _Installed.read(root);
      var changed = false;
      if (installed.pendingDeletes.isNotEmpty) {
        await _freePending(root, installed, _deleteEntity);
        changed = true;
      }
      // What a move left in the old folder
      final former = installed.rest[_movedFrom];
      if (former is String && await _emptyFormer(Directory(former), _deleteEntity)) {
        installed.rest.remove(_movedFrom);
        changed = true;
      }
      if (changed) {
        await installed.write(root);
      }
    } catch (error, stack) {
      _log.warning('the files noted for deletion could not be freed', error, stack);
    }
  }();

  /// The key of installed.json that names the folder the components were moved from, while files of the app are left
  /// in it
  static const _movedFrom = 'movedFrom';

  /// Empties the folders of the app in [old], the folder a move left; true once nothing of the app is left there
  static Future<bool> _emptyFormer(Directory old, Future<void> Function(FileSystemEntity entity) delete) async {
    if (!old.existsSync()) {
      return true;
    }
    final kept = <String>[];
    for (final name in _ownFolders) {
      if (FileSystemEntity.typeSync(p.join(old.path, name), followLinks: false) != FileSystemEntityType.notFound) {
        kept.addAll(await _emptyIn(old, name, delete));
      }
    }
    for (final name in [installedFileName, '$installedFileName.tmp']) {
      final file = File(p.join(old.path, name));
      if (FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.file) {
        await _tryDelete(file, delete);
      }
    }
    if (kept.isNotEmpty) {
      return false;
    }
    try {
      // Only when empty: a file of the user stays, and so does the folder
      await old.delete();
    } on FileSystemException {
      // Not empty
    }
    return true;
  }

  @visibleForTesting
  static void resetStartPassForTests() => _startPass = null;

  /// Deletes what [installed] notes for deletion, inside [root] only; keeps the paths still refused
  static Future<void> _freePending(
    Directory root,
    _Installed installed,
    Future<void> Function(FileSystemEntity entity) delete,
  ) async {
    final kept = <String>[];
    for (final path in installed.pendingDeletes) {
      final entity = _entityIn(root, path);
      if (entity == null) {
        _log.warning('a path out of the components folder is not deleted: $path');
        continue;
      }
      if (!await _tryDelete(entity, delete)) {
        kept.add(path);
      }
    }
    installed.pendingDeletes = kept;
  }

  /// The file, folder or link at [relative] ("/" between folders) inside [root], null when it would be outside
  static FileSystemEntity? _entityIn(Directory root, String relative) {
    final path = p.normalize(p.joinAll([root.path, ...relative.split('/')]));
    if (!p.isWithin(root.path, path)) {
      return null;
    }
    if (FileSystemEntity.isLinkSync(path)) {
      return Link(path);
    }
    return FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);
  }

  /// True when [entity] is gone
  static Future<bool> _tryDelete(FileSystemEntity entity, Future<void> Function(FileSystemEntity entity) delete) async {
    try {
      await delete(entity);
      return true;
    } on PathNotFoundException {
      return true;
    } on FileSystemException catch (error) {
      _log.info('kept for the next start: ${entity.path} ($error)');
      return false;
    }
  }

  /// Reads installed.json once: frees the files noted for deletion, drops the older versions, checks the size of
  /// each installed file and cleans tmp/
  Future<void> load() => _loaded ??= _load().catchError((Object error, StackTrace stack) {
    // Tried again at the next call
    _loaded = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _load() async {
    await _startPass;
    final root = _root = await _folder();
    _installed = await _Installed.read(root);
    var changed = false;
    if (_installed.pendingDeletes.isNotEmpty) {
      final before = _installed.pendingDeletes.length;
      await _freePending(root, _installed, _delete);
      changed = _installed.pendingDeletes.length != before;
    }
    for (final component in catalogue) {
      final entry = _installed.components[component.id];
      if (entry != null && entry['sha256'] != component.sha256) {
        // An older version: its file goes, the new one is downloaded when asked
        _log.info('${component.id}: version ${entry['version']} replaced by ${component.version}');
        final path = entry['path'];
        if (path is String) {
          final old = _entityIn(root, path);
          if (old != null && !await _tryDelete(old, _delete)) {
            _installed.pendingDeletes.add(path);
          }
        }
        _installed.components.remove(component.id);
        changed = true;
      }
    }
    if (changed && !await _trySave()) {
      // The files it no longer names are gone: the next write carries the change, else the next load does it again
      _log.warning('the cleaned installed.json waits for the next write');
    }
    await _cleanTmp(root);
    for (final component in catalogue) {
      _statuses[component.id] = AiComponentStatus(await _stateOnDisk(component));
    }
    _notify();
  }

  /// Keeps only the .part of the catalogue's files, which a download resumes
  Future<void> _cleanTmp(Directory root) async {
    final tmp = Directory(p.join(root.path, _tmp));
    if (!tmp.existsSync()) {
      return;
    }
    final parts = {
      for (final component in catalogue) ...[
        '${component.assetName}.part',
        if (component.notices != null) '${component.notices!.assetName}.part',
      ],
    };
    await for (final entity in tmp.list()) {
      if (!parts.contains(p.basename(entity.path))) {
        await _tryDelete(entity, _delete);
      }
    }
  }

  /// The file the engines use: the file of the component, or the program of an archive
  File _fileOf(AiComponent component) => File(p.joinAll([_root!.path, ...component.mainPath.split('/')]));

  /// What the component installs: its file, or the folder of an archive
  FileSystemEntity _installedOf(AiComponent component) {
    final path = p.joinAll([_root!.path, ...component.installPath.split('/')]);
    return component.isArchive ? Directory(path) : File(path);
  }

  /// The file of [archive] (a component of kind archive) under [path] of its folder
  File _archiveFileOf(AiComponent archive, String path) =>
      File(p.joinAll([_root!.path, ...archive.installPath.split('/'), ...path.split('/')]));

  File _partOf(AiComponent component) => File(p.join(_root!.path, _tmp, '${component.assetName}.part'));

  File _licenceIn(Directory root, AiComponent component) => File(p.join(root.path, _licenses, '${component.id}.txt'));

  /// The licence copied at the installation of [component] (it may not exist)
  Future<File> licenceOf(AiComponent component) async => _licenceIn(_root ?? await _folder(), component);

  /// The notices downloaded with [component] (ONNX Runtime), null for a component without notices; the file may not
  /// exist
  Future<File?> noticesOf(AiComponent component) async {
    final notices = component.noticesDownload;
    if (notices == null) {
      return null;
    }
    return File(p.joinAll([(_root ?? await _folder()).path, ...notices.installPath.split('/')]));
  }

  /// The state the disk gives, the size checked
  Future<AiComponentState> _stateOnDisk(AiComponent component) async {
    if (_installed.pendingDeletes.contains(component.installPath)) {
      return AiComponentState.removedNextStart;
    }
    final entry = _installed.components[component.id];
    if (entry == null) {
      return AiComponentState.notInstalled;
    }
    final expected = component.isArchive
        ? {for (final file in component.archiveFiles) _archiveFileOf(component, file.path): file.size}
        : {_fileOf(component): component.size};
    for (final MapEntry(key: file, value: wanted) in expected.entries) {
      final size = file.existsSync() ? await file.length() : -1;
      if (size != wanted) {
        _log.warning('${component.id}: ${file.path} has $size bytes on the disk, $wanted expected');
        return AiComponentState.damaged;
      }
    }
    return AiComponentState.installed;
  }

  /// The status of [component]; notInstalled before load()
  AiComponentStatus statusOf(AiComponent component) =>
      _statuses[component.id] ?? const AiComponentStatus(AiComponentState.notInstalled);

  void _set(AiComponent component, AiComponentStatus status) {
    _statuses[component.id] = status;
    _notify();
  }

  bool _disposed = false;

  void _notify() {
    // A download that ends after the provider went away has nobody to tell
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Stops the downloads under way; their .part files stay
  @override
  void dispose() {
    _disposed = true;
    for (final cancel in _cancels.values) {
      cancel.cancel();
    }
    super.dispose();
  }

  /// The file of [component] for the engine, when it is installed and still has its size (checked at each call);
  /// null otherwise, the state then says why
  Future<File?> verifiedFile(AiComponent component) async {
    await load();
    if (_installs.containsKey(component.id)) {
      return null;
    }
    final state = await _stateOnDisk(component);
    if (state != statusOf(component).state) {
      _set(component, AiComponentStatus(state));
    }
    return state == AiComponentState.installed ? _fileOf(component) : null;
  }

  /// Downloads and installs [component]; a second call during the download waits for the same one. Throws an
  /// [AiDownloadException], also kept in the status for the screens.
  Future<void> install(AiComponent component) {
    final running = _installs[component.id];
    if (running != null) {
      return running;
    }
    // Registered at once, so that a cancel asked right after the call is seen
    final cancel = _cancels[component.id] = AiDownloadCancel();
    return _installs[component.id] = _run(component, cancel);
  }

  Future<void> _run(AiComponent component, AiDownloadCancel cancel) async {
    try {
      await _install(component, cancel);
    } finally {
      // The future removed is the one of this very call, which the callers await
      _installs.removeWhere((id, _) => id == component.id);
      _cancels.remove(component.id);
    }
  }

  Future<void> _install(AiComponent component, AiDownloadCancel cancel) async {
    try {
      await load();
      if (cancel.isCancelled) {
        throw const AiDownloadException(AiDownloadFailure.cancelled);
      }
      if (!component.isComplete) {
        throw AiDownloadException(AiDownloadFailure.incomplete, component.id);
      }
      final notices = component.noticesDownload;
      if (await _stateOnDisk(component) == AiComponentState.installed &&
          (notices == null || _fileOf(notices).existsSync())) {
        _set(component, const AiComponentStatus(AiComponentState.installed));
        return;
      }
      _set(component, AiComponentStatus(AiComponentState.downloading, total: component.bytesToDownload));
      // A file waiting for its deletion is wanted again: it stays if its sum is right
      if (_installed.pendingDeletes.remove(component.installPath)) {
        await _save(undo: () => _installed.pendingDeletes.add(component.installPath));
      }
      // An archive comes into tmp/, then its files are unpacked into their folder
      final target = component.isArchive ? File(p.join(_root!.path, _tmp, component.assetName)) : _fileOf(component);
      String source;
      if (component.isArchive ? await _hasArchiveFiles(component) : await _hasSum(target, component)) {
        source = alreadyOnDisk;
      } else {
        // Refused before the first byte when the drive cannot hold it
        final shortage = await spaceShortage([component]);
        if (shortage != null) {
          throw AiDownloadException(AiDownloadFailure.notEnoughSpace, '$shortage', shortage);
        }
        var shown = -1;
        final uri = await _downloader.download(
          component,
          target: target,
          part: _partOf(component),
          cancel: cancel,
          onProgress: (received, total) {
            // At most a thousand notifications per download
            final step = total == null || total == 0 ? received >> 20 : received * 1000 ~/ total;
            if (step != shown) {
              shown = step;
              _set(component, AiComponentStatus(AiComponentState.downloading, received: received, total: total));
            }
          },
        );
        source = uri.toString();
        if (component.isArchive) {
          try {
            await installAiArchive(
              target,
              _installedOf(component) as Directory,
              component.archiveFiles,
              setExecutable: _setExecutable,
            );
          } finally {
            await _tryDelete(target, _delete);
          }
        }
      }
      // The notices of the libraries inside come with the library: without them, it is not installed (the library
      // stays in place and is kept by the next call when its sum is right)
      if (notices != null && !await _hasSum(_fileOf(notices), notices)) {
        await _downloader.download(notices, target: _fileOf(notices), part: _partOf(notices), cancel: cancel);
      }
      final installedAt = _now();
      await _writeLicence(component, source: source, installedAt: installedAt);
      final before = _installed.components[component.id];
      _installed.components[component.id] = {
        'version': component.version,
        'path': component.installPath,
        'size': component.size,
        'sha256': component.sha256,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'source': source,
      };
      // Not written: not installed, and the next call writes it (the file in place is kept when its sum is right)
      await _save(
        undo: () {
          if (before == null) {
            _installed.components.remove(component.id);
          } else {
            _installed.components[component.id] = before;
          }
        },
      );
      _set(component, const AiComponentStatus(AiComponentState.installed));
    } on AiDownloadException catch (error) {
      _set(component, AiComponentStatus(await _stateAfterFailure(component), failure: error));
      rethrow;
    } on FileSystemException catch (error) {
      final failure = AiDownloadException(
        isDiskFull(error) ? AiDownloadFailure.diskFull : AiDownloadFailure.writeFailed,
        error.toString(),
      );
      _set(component, AiComponentStatus(await _stateAfterFailure(component), failure: failure));
      throw failure;
    }
  }

  Future<AiComponentState> _stateAfterFailure(AiComponent component) async =>
      _root == null ? AiComponentState.notInstalled : _stateOnDisk(component);

  /// Whether every file of the archive [component] is in its folder with its size and SHA-256
  Future<bool> _hasArchiveFiles(AiComponent component) async {
    for (final file in component.archiveFiles) {
      final installed = _archiveFileOf(component, file.path);
      if (!installed.existsSync() ||
          await installed.length() != file.size ||
          (await sha256.bind(installed.openRead()).first).toString() != file.sha256) {
        return false;
      }
    }
    return component.archiveFiles.isNotEmpty;
  }

  /// Whether [file] is there with the size and the SHA-256 of [component]
  Future<bool> _hasSum(File file, AiComponent component) async {
    if (!file.existsSync() || await file.length() != component.size) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() == component.sha256;
  }

  Future<void> _writeLicence(AiComponent component, {required String source, required DateTime installedAt}) async {
    final licence = _licenceIn(_root!, component);
    await licence.parent.create(recursive: true);
    final temporary = File('${licence.path}.tmp');
    await temporary.writeAsString(aiComponentLicenceNotice(component, source: source, installedAt: installedAt));
    await temporary.rename(licence.path);
  }

  /// What installing [components] lacks on the drive of the components, those already installed left out; null when
  /// the space is there or cannot be read
  Future<AiSpaceShortage?> spaceShortage(Iterable<AiComponent> components) async {
    final reader = freeSpace;
    if (reader == null) {
      return null;
    }
    await load();
    final missing = {
      for (final component in components)
        if (statusOf(component).state != AiComponentState.installed) component.id: component,
    };
    final needed = aiSpaceNeeded(diskBytesOf(missing.values));
    if (needed == 0) {
      return null;
    }
    final space = await reader(_root!);
    if (space == null || space.free >= needed) {
      return null;
    }
    return AiSpaceShortage(needed: needed, free: space.free, volume: space.volume);
  }

  /// Stops the download of [component], if one runs; its .part stays for the next one
  void cancel(AiComponent component) => _cancels[component.id]?.cancel();

  /// Removes [component]: its file, its licence and its .part. Refused while a conversion runs.
  Future<AiRemoveOutcome> remove(AiComponent component) async {
    await load();
    if (inUse()) {
      return AiRemoveOutcome.busy;
    }
    await _stop(component);
    final root = _root!;
    final path = component.installPath;
    // Written first: the entry goes and the file is noted for the next start, then the file goes
    final entry = _installed.components.remove(component.id);
    final noted = _installedOf(component).existsSync() && !_installed.pendingDeletes.contains(path);
    if (noted) {
      _installed.pendingDeletes.add(path);
    }
    if (entry != null || noted) {
      final written = await _trySave(
        undo: () {
          if (entry != null) {
            _installed.components[component.id] = entry;
          }
          if (noted) {
            _installed.pendingDeletes.remove(path);
          }
        },
      );
      if (!written) {
        return AiRemoveOutcome.writeFailed;
      }
    }
    final deferred = !await _tryDelete(_installedOf(component), _delete);
    final notices = component.noticesDownload;
    for (final other in [
      _licenceIn(root, component),
      _partOf(component),
      File('${_partOf(component).path}.unpack'),
      if (notices != null) ...[_fileOf(notices), _partOf(notices)],
    ]) {
      await _tryDelete(other, _delete);
    }
    if (!deferred && _installed.pendingDeletes.remove(path) && !await _trySave()) {
      // The file is gone: the start pass finds nothing to delete at the path still noted
      _log.warning('$path stays noted in installed.json until the next write');
    }
    _set(component, AiComponentStatus(deferred ? AiComponentState.removedNextStart : AiComponentState.notInstalled));
    return deferred ? AiRemoveOutcome.nextStart : AiRemoveOutcome.removed;
  }

  /// Whether every component of [group] on [platform] is installed
  bool _isInstalled(AiGroupComponents group) =>
      group.all.every((component) => statusOf(component).state == AiComponentState.installed);

  /// The other groups of [platform], installed, that need [component] beside the group [besides]: a shared component
  /// stays while one of them does (design-final 2026-10-27, section 7.1, point 7)
  List<AiFeatureGroup> groupsUsing(AiPlatform platform, AiComponent component, {required AiFeatureGroup besides}) => [
    for (final group in aiComponentGroupsFor(platform, catalogue: catalogue))
      if (group.group != besides && group.all.any((other) => other.id == component.id) && _isInstalled(group))
        group.group,
  ];

  /// Removes the components of [group] on [platform], those another installed group needs apart, which are given
  /// back in [AiGroupRemoval.kept]. Refused while a conversion runs.
  Future<AiGroupRemoval> removeGroup(AiPlatform platform, AiFeatureGroup group) async {
    await load();
    if (inUse()) {
      return const AiGroupRemoval(AiRemoveOutcome.busy, []);
    }
    final components = aiComponentGroupsFor(
      platform,
      catalogue: catalogue,
    ).where((entry) => entry.group == group).expand((entry) => entry.all).toList();
    final kept = [
      for (final component in components)
        if (groupsUsing(platform, component, besides: group).isNotEmpty) component,
    ];
    var outcome = AiRemoveOutcome.removed;
    for (final component in components.where((component) => !kept.contains(component))) {
      final removed = await remove(component);
      // The worst outcome is the one said: a write that failed, a refusal, then the space at the next start
      if (removed.index > outcome.index) {
        outcome = removed;
      }
    }
    return AiGroupRemoval(outcome, kept);
  }

  /// Removes the folders of the app in the folder of the components: every component (those of other versions too),
  /// the licences and the .part files, and installed.json (the keys of a newer version too). Nothing else in the
  /// folder, and never what a link leads to. Refused while a conversion runs.
  Future<AiRemoveOutcome> removeAll() async {
    await load();
    if (inUse()) {
      return AiRemoveOutcome.busy;
    }
    for (final component in catalogue) {
      await _stop(component);
    }
    final root = _root!;
    final folders = [
      for (final name in _ownFolders)
        if (FileSystemEntity.typeSync(p.join(root.path, name), followLinks: false) != FileSystemEntityType.notFound)
          name,
    ];
    // Written first: everything is forgotten and the folders are noted for the next start, then they go
    final before = _installed;
    _installed = _Installed(pendingDeletes: [...folders]);
    if (!await _trySave(undo: () => _installed = before)) {
      return AiRemoveOutcome.writeFailed;
    }
    final kept = <String>[];
    for (final name in folders) {
      kept.addAll(await _empty(root, name));
    }
    final leftover = File(p.join(root.path, '$installedFileName.tmp'));
    if (FileSystemEntity.typeSync(leftover.path, followLinks: false) == FileSystemEntityType.file) {
      await _tryDelete(leftover, _delete);
    }
    _installed.pendingDeletes = kept;
    if (!await _trySave()) {
      // The folders stay noted: the start pass deletes what is left of them
      _log.warning('the folders of the components stay noted in installed.json until the next start');
    }
    for (final component in catalogue) {
      final path = component.installPath;
      _statuses[component.id] = AiComponentStatus(
        kept.any((left) => left == path || left.startsWith('$path/'))
            ? AiComponentState.removedNextStart
            : AiComponentState.notInstalled,
      );
    }
    _notify();
    return kept.isEmpty ? AiRemoveOutcome.removed : AiRemoveOutcome.nextStart;
  }

  /// Deletes the folder [name] of [root] and what it holds, a link as a link (never followed); returns the paths the
  /// system keeps ("/" between folders)
  Future<List<String>> _empty(Directory root, String name) => _emptyIn(root, name, _delete);

  static Future<List<String>> _emptyIn(
    Directory root,
    String name,
    Future<void> Function(FileSystemEntity entity) delete,
  ) async {
    final path = p.join(root.path, name);
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
      // A file or a link where the app keeps a folder
      final entity = FileSystemEntity.isLinkSync(path) ? Link(path) : File(path);
      return await _tryDelete(entity, delete) ? const [] : [name];
    }
    final kept = <String>[];
    final entities = await Directory(path).list(recursive: true, followLinks: false).toList();
    for (final entity in entities) {
      if (entity is! Directory && !await _tryDelete(entity, delete)) {
        kept.add(p.split(p.relative(entity.path, from: root.path)).join('/'));
      }
    }
    // The folders left empty, the deepest first, this one last
    final folders = [...entities.whereType<Directory>(), Directory(path)]
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final folder in folders) {
      try {
        await folder.delete();
      } on FileSystemException {
        // Not empty: it holds a file kept for the next start
      }
    }
    return kept;
  }

  /// Moves the components into [target], a folder empty or not made yet; [remember] keeps it as the folder of the
  /// components (desktop_ai.json) once every copy is checked, before the old folder is emptied. [onProgress] gets the
  /// bytes copied out of those to copy. See the top of this file.
  Future<AiMoveResult> moveTo(
    Directory target, {
    required Future<void> Function(Directory folder) remember,
    void Function(int done, int total)? onProgress,
  }) async {
    await load();
    if (inUse() || _installs.isNotEmpty) {
      return const AiMoveResult(AiMoveOutcome.busy);
    }
    final old = _root!;
    final destination = Directory(p.normalize(target.absolute.path));
    if (p.equals(destination.path, old.path)) {
      return const AiMoveResult(AiMoveOutcome.same);
    }
    if (p.isWithin(old.path, destination.path) ||
        p.isWithin(destination.path, old.path) ||
        (destination.existsSync() && destination.listSync().isNotEmpty)) {
      return const AiMoveResult(AiMoveOutcome.notEmpty);
    }

    // What to copy: each installed component, its notices and its licence, with the sums of the catalogue
    final copies = <({String path, int? size, String? sha256})>[];
    final kept = <String, Map<String, dynamic>>{};
    for (final MapEntry(key: id, value: entry) in _installed.components.entries) {
      final component = catalogue.where((component) => component.id == id).firstOrNull;
      if (component == null) {
        // A component of a newer version: its file goes along as it is
        final path = entry['path'];
        if (path is String && _entityIn(old, path) is File && File(p.join(old.path, path)).existsSync()) {
          copies.add((path: path, size: null, sha256: null));
          kept[id] = entry;
        }
        continue;
      }
      if (statusOf(component).state != AiComponentState.installed) {
        continue;
      }
      if (component.isArchive) {
        for (final file in component.archiveFiles) {
          copies.add((path: '${component.installPath}/${file.path}', size: file.size, sha256: file.sha256));
        }
      } else {
        copies.add((path: component.installPath, size: component.size, sha256: component.sha256));
      }
      final notices = component.noticesDownload;
      if (notices != null && _fileOf(notices).existsSync()) {
        copies.add((path: notices.installPath, size: notices.size, sha256: notices.sha256));
      }
      if (_licenceIn(old, component).existsSync()) {
        copies.add((path: '$_licenses/${component.id}.txt', size: null, sha256: null));
      }
      kept[id] = entry;
    }
    final sizes = [
      for (final copy in copies) copy.size ?? File(p.joinAll([old.path, ...copy.path.split('/')])).lengthSync(),
    ];
    final total = sizes.fold<int>(0, (sum, size) => sum + size);
    final reader = freeSpace;
    if (reader != null && total > 0) {
      final space = await reader(destination);
      final needed = aiSpaceNeeded(total);
      if (space != null && space.free < needed) {
        return AiMoveResult(
          AiMoveOutcome.notEnoughSpace,
          shortage: AiSpaceShortage(needed: needed, free: space.free, volume: space.volume),
        );
      }
    }

    final moved = _Installed(components: kept, rest: {..._installed.rest, _movedFrom: old.path});
    try {
      var done = 0;
      onProgress?.call(0, total);
      for (final copy in copies) {
        done = await _copyChecked(old, destination, copy, done, total, onProgress);
      }
      await moved.write(destination);
      await remember(destination);
    } on Object catch (error) {
      _log.warning('the components were not moved to ${destination.path}: $error');
      try {
        if (destination.existsSync()) {
          await destination.delete(recursive: true);
        }
      } on FileSystemException catch (failure) {
        _log.warning('the copies in ${destination.path} could not all be deleted: $failure');
      }
      return AiMoveResult(AiMoveOutcome.failed, detail: '$error');
    }

    // The new folder is the one now: the old one is emptied, what the system holds left to the next start
    _root = destination;
    _installed = moved;
    final emptied = await _emptyFormer(old, _delete);
    if (emptied) {
      _installed.rest.remove(_movedFrom);
      await _trySave();
    }
    _notify();
    return AiMoveResult(emptied ? AiMoveOutcome.moved : AiMoveOutcome.movedNextStart);
  }

  /// Copies [copy] from [from] into [to], beside then renamed, its size and sum checked; returns the bytes copied so far
  Future<int> _copyChecked(
    Directory from,
    Directory to,
    ({String path, int? size, String? sha256}) copy,
    int done,
    int total,
    void Function(int done, int total)? onProgress,
  ) async {
    final source = File(p.joinAll([from.path, ...copy.path.split('/')]));
    final target = File(p.joinAll([to.path, ...copy.path.split('/')]));
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final sink = temporary.openWrite();
    var copied = 0;
    try {
      await for (final chunk in source.openRead()) {
        hash.add(chunk);
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(done + copied, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hash.close();
    if ((copy.size != null && copied != copy.size) || (copy.sha256 != null && digest.value.toString() != copy.sha256)) {
      throw FileSystemException('the copy of ${copy.path} is not the file of the catalogue', target.path);
    }
    await temporary.rename(target.path);
    return done + copied;
  }

  /// Cancels the download of [component] and waits for its end
  Future<void> _stop(AiComponent component) async {
    final running = _installs[component.id];
    if (running == null) {
      return;
    }
    cancel(component);
    try {
      await running;
    } on Object {
      // Its failure is in its status
    }
  }

  /// The real space the folder takes, the .part files included
  Future<int> spaceUsed() async {
    final root = _root ?? await _folder();
    if (!root.existsSync()) {
      return 0;
    }
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // Gone meanwhile
        }
      }
    }
    return total;
  }

  /// Writes installed.json, one write after the other; a write that failed does not stop the next one. When this one
  /// fails, [undo] puts the memory back as the disk still has it, then the error is thrown.
  Future<void> _save({void Function()? undo}) async {
    final root = _root!;
    final installed = _installed;
    final write = _saving = _saving.catchError((Object _) {}).then((_) => installed.write(root));
    try {
      await write;
    } on FileSystemException {
      undo?.call();
      rethrow;
    }
  }

  /// [_save], false when installed.json could not be written
  Future<bool> _trySave({void Function()? undo}) async {
    try {
      await _save(undo: undo);
      return true;
    } on FileSystemException catch (error, stack) {
      _log.warning('$installedFileName could not be written', error, stack);
      return false;
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// installed.json: the components installed, the files whose deletion waits for the next start, and the keys of a
/// newer version kept as they are
class _Installed {
  _Installed({Map<String, Map<String, dynamic>>? components, List<String>? pendingDeletes, Map<String, dynamic>? rest})
    : components = components ?? {},
      pendingDeletes = pendingDeletes ?? [],
      rest = rest ?? {};

  final Map<String, Map<String, dynamic>> components;
  List<String> pendingDeletes;
  final Map<String, dynamic> rest;

  static const _formatVersion = 1;

  static File fileIn(Directory root) => File(p.join(root.path, AiComponentsService.installedFileName));

  static Future<_Installed> read(Directory root) async {
    final file = fileIn(root);
    if (!file.existsSync()) {
      return _Installed();
    }
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      final components = <String, Map<String, dynamic>>{};
      final entries = json['components'];
      if (entries is Map<String, dynamic>) {
        for (final MapEntry(:key, :value) in entries.entries) {
          if (value is Map<String, dynamic>) {
            components[key] = value;
          }
        }
      }
      final pending = json['pendingDeletes'];
      return _Installed(
        components: components,
        pendingDeletes: [if (pending is List) ...pending.whereType<String>()],
        rest: {
          for (final MapEntry(:key, :value) in json.entries)
            if (!const {'formatVersion', 'components', 'pendingDeletes'}.contains(key)) key: value,
        },
      );
    } on Object catch (error) {
      _log.warning('${file.path} could not be read, taken as empty: $error');
      return _Installed();
    }
  }

  /// A whole new file renamed over the old one; no file once nothing is left to say
  Future<void> write(Directory root) async {
    final file = fileIn(root);
    if (components.isEmpty && pendingDeletes.isEmpty && rest.isEmpty) {
      try {
        await file.delete();
      } on PathNotFoundException {
        // Never written
      }
      return;
    }
    await root.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({...rest, 'formatVersion': _formatVersion, 'components': components, 'pendingDeletes': pendingDeletes}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
