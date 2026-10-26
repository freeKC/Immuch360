// The AI components on this device (design-final 2026-10-26, section 2.2), shared by the computers and the Quest:
// which are installed, their download when the user asks for it (never otherwise), the size of each file checked at
// each load (the SHA-256 is checked once, at the download), removal, and installed.json.
//
// The folder (aiComponentsFolderProvider) holds runtime/, models/, licenses/ (the licence of each component, copied at
// its installation), tmp/ (the .part files, kept to resume a download) and installed.json (version, size, SHA-256,
// date and source of each component, and the files whose deletion waits for the next start). Windows does not delete
// a DLL that is loaded: removing ONNX Runtime after a conversion notes the file, and the pass of the next start
// (freePendingAtStart, run by the desktop start before anything loads a component) deletes it. A removal is refused
// while a conversion runs (inUse).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AiComponentsService');

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
  }) : _downloader = downloader ?? AiComponentDownloader(),
       inUse = inUse ?? _never,
       _now = now ?? DateTime.now,
       _delete = delete ?? _deleteEntity;

  final Future<Directory> Function() _folder;
  final AiComponentDownloader _downloader;
  final List<AiComponent> catalogue;
  final DateTime Function() _now;
  final Future<void> Function(FileSystemEntity entity) _delete;

  /// Whether a conversion runs, set by the engine: removal waits for its end
  bool Function() inUse;

  static bool _never() => false;
  static Future<void> _deleteEntity(FileSystemEntity entity) => entity.delete(recursive: true);

  static const installedFileName = 'installed.json';
  static const _tmp = 'tmp';
  static const _licenses = 'licenses';

  /// The source written in installed.json for a file that was already in place with the right sum
  static const alreadyOnDisk = 'already on disk';

  Directory? _root;
  _Installed _installed = _Installed();
  Future<void>? _loaded;
  final _statuses = <String, AiComponentStatus>{};
  final _installs = <String, Future<void>>{};
  final _cancels = <String, AiDownloadCancel>{};
  Future<void> _saving = Future.value();

  /// The bytes to download for [components], from the catalogue
  static int downloadBytesOf(Iterable<AiComponent> components) =>
      components.fold(0, (sum, component) => sum + (component.bytesToDownload ?? 0));

  /// The space [components] take once installed, from the catalogue
  static int diskBytesOf(Iterable<AiComponent> components) =>
      components.fold(0, (sum, component) => sum + (component.size ?? 0));

  static Future<void>? _startPass;

  /// The pass of the start: deletes the files noted for the next start, once per process, before anything loads a
  /// component. The services wait for it before they read installed.json.
  static Future<void> freePendingAtStart(Future<Directory> Function() folder) => _startPass ??= () async {
    try {
      final root = await folder();
      final installed = await _Installed.read(root);
      if (installed.pendingDeletes.isEmpty) {
        return;
      }
      await _freePending(root, installed, _deleteEntity);
      await installed.write(root);
    } catch (error, stack) {
      _log.warning('the files noted for deletion could not be freed', error, stack);
    }
  }();

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

  /// The file or folder at [relative] ("/" between folders) inside [root], null when it would be outside
  static FileSystemEntity? _entityIn(Directory root, String relative) {
    final path = p.normalize(p.joinAll([root.path, ...relative.split('/')]));
    if (!p.isWithin(root.path, path)) {
      return null;
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
    if (changed) {
      await _save();
    }
    await _cleanTmp(root);
    for (final component in catalogue) {
      _statuses[component.id] = AiComponentStatus(await _stateOnDisk(component));
    }
    notifyListeners();
  }

  /// Keeps only the .part of the catalogue's files, which a download resumes
  Future<void> _cleanTmp(Directory root) async {
    final tmp = Directory(p.join(root.path, _tmp));
    if (!tmp.existsSync()) {
      return;
    }
    final parts = {for (final component in catalogue) '${component.assetName}.part'};
    await for (final entity in tmp.list()) {
      if (!parts.contains(p.basename(entity.path))) {
        await _tryDelete(entity, _delete);
      }
    }
  }

  File _fileOf(AiComponent component) => File(p.joinAll([_root!.path, ...component.installPath.split('/')]));

  File _partOf(AiComponent component) => File(p.join(_root!.path, _tmp, '${component.assetName}.part'));

  File _licenceIn(Directory root, AiComponent component) => File(p.join(root.path, _licenses, '${component.id}.txt'));

  /// The licence copied at the installation of [component] (it may not exist)
  Future<File> licenceOf(AiComponent component) async => _licenceIn(_root ?? await _folder(), component);

  /// The state the disk gives, the size checked
  Future<AiComponentState> _stateOnDisk(AiComponent component) async {
    if (_installed.pendingDeletes.contains(component.installPath)) {
      return AiComponentState.removedNextStart;
    }
    final entry = _installed.components[component.id];
    if (entry == null) {
      return AiComponentState.notInstalled;
    }
    final file = _fileOf(component);
    final size = file.existsSync() ? await file.length() : -1;
    if (size != component.size) {
      _log.warning('${component.id}: $size bytes on the disk, ${component.size} expected');
      return AiComponentState.damaged;
    }
    return AiComponentState.installed;
  }

  /// The status of [component]; notInstalled before load()
  AiComponentStatus statusOf(AiComponent component) =>
      _statuses[component.id] ?? const AiComponentStatus(AiComponentState.notInstalled);

  void _set(AiComponent component, AiComponentStatus status) {
    _statuses[component.id] = status;
    notifyListeners();
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
      if (await _stateOnDisk(component) == AiComponentState.installed) {
        _set(component, const AiComponentStatus(AiComponentState.installed));
        return;
      }
      _set(component, AiComponentStatus(AiComponentState.downloading, total: component.bytesToDownload));
      // A file waiting for its deletion is wanted again: it stays if its sum is right
      if (_installed.pendingDeletes.remove(component.installPath)) {
        await _save();
      }
      final target = _fileOf(component);
      String source;
      if (await _hasSum(target, component)) {
        source = alreadyOnDisk;
      } else {
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
      }
      final installedAt = _now();
      await _writeLicence(component, source: Uri.parse(source), installedAt: installedAt);
      _installed.components[component.id] = {
        'version': component.version,
        'path': component.installPath,
        'size': component.size,
        'sha256': component.sha256,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'source': source,
      };
      await _save();
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

  /// Whether [file] is there with the size and the SHA-256 of [component]
  Future<bool> _hasSum(File file, AiComponent component) async {
    if (!file.existsSync() || await file.length() != component.size) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() == component.sha256;
  }

  Future<void> _writeLicence(AiComponent component, {required Uri source, required DateTime installedAt}) async {
    final licence = _licenceIn(_root!, component);
    await licence.parent.create(recursive: true);
    final temporary = File('${licence.path}.tmp');
    await temporary.writeAsString(aiComponentLicenceNotice(component, source: source, installedAt: installedAt));
    await temporary.rename(licence.path);
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
    var deferred = false;
    if (!await _tryDelete(_fileOf(component), _delete)) {
      _installed.pendingDeletes.add(component.installPath);
      deferred = true;
    }
    for (final other in [_licenceIn(root, component), _partOf(component), File('${_partOf(component).path}.unpack')]) {
      await _tryDelete(other, _delete);
    }
    _installed.components.remove(component.id);
    await _save();
    _set(component, AiComponentStatus(deferred ? AiComponentState.removedNextStart : AiComponentState.notInstalled));
    return deferred ? AiRemoveOutcome.nextStart : AiRemoveOutcome.removed;
  }

  /// Removes everything in the folder: every component (those of other versions too), the licences and the .part
  /// files. Refused while a conversion runs.
  Future<AiRemoveOutcome> removeAll() async {
    await load();
    if (inUse()) {
      return AiRemoveOutcome.busy;
    }
    for (final component in catalogue) {
      await _stop(component);
    }
    final root = _root!;
    final kept = <String>[];
    if (root.existsSync()) {
      final files = await root.list(recursive: true).where((entity) => entity is File).toList();
      for (final file in files) {
        if (p.equals(file.path, p.join(root.path, installedFileName))) {
          continue;
        }
        if (!await _tryDelete(file, _delete)) {
          kept.add(p.split(p.relative(file.path, from: root.path)).join('/'));
        }
      }
      // The folders left empty, the deepest first
      final folders = await root.list(recursive: true).where((entity) => entity is Directory).toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final folder in folders) {
        try {
          await folder.delete();
        } on FileSystemException {
          // Not empty: it holds a file kept for the next start
        }
      }
    }
    _installed
      ..components.clear()
      ..pendingDeletes = kept;
    await _save();
    for (final component in catalogue) {
      _statuses[component.id] = AiComponentStatus(
        kept.contains(component.installPath) ? AiComponentState.removedNextStart : AiComponentState.notInstalled,
      );
    }
    notifyListeners();
    return kept.isEmpty ? AiRemoveOutcome.removed : AiRemoveOutcome.nextStart;
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

  /// Writes installed.json, one write after the other
  Future<void> _save() {
    final root = _root!;
    final installed = _installed;
    return _saving = _saving.then((_) => installed.write(root));
  }
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
