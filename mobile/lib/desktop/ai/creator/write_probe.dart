// The check that a destination folder accepts a new file, made without any test file (design-final 2026-10-26,
// section 2.5). For each distinct folder of a selection, fifty at most, the partial file of the first job of that folder
// is created through the SafeWriter, noted in the journal and left empty: the job takes it over at the launch. A folder
// beyond the fiftieth is checked by the partial file of its own job, at its turn. When the dialog closes without
// launching, the partial files not taken are deleted. destination.dart decides when a folder may be checked: when the
// dialog opens for a local folder, only after the user's yes for a network one. A refusal is thus known before a batch
// starts, and the check leaves no file behind.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';

/// A folder to check, through the first job that writes there
class ProbeRequest {
  const ProbeRequest({required this.jobId, required this.folder, required this.finalName, this.createFolder = false});

  final String jobId;
  final String folder;

  /// The name of the 3D photo of the job, which names its partial file
  final String finalName;

  /// Whether the folder is created when it is missing: a chosen folder such as Downloads/Immuch360, never the folder
  /// of an original
  final bool createFolder;
}

/// What the check of a folder found
enum ProbeStatus {
  /// A partial file was created there: the folder accepts new files
  ready,

  /// Beyond the fiftieth folder: the partial file of its job checks it at its turn
  notChecked,

  /// The folder refuses new files
  readOnly,

  /// No space left
  diskFull,

  /// The folder is not there (a drive unplugged, a share gone)
  missing,

  /// Another failure, with the message of the system
  failed,
}

/// The check of a folder
class ProbeResult {
  const ProbeResult(this.status, {this.message});

  final ProbeStatus status;
  final String? message;

  /// Whether the 3D photos may go there
  bool get accepted => status == ProbeStatus.ready || status == ProbeStatus.notChecked;

  @override
  String toString() => 'ProbeResult(${status.name}${message == null ? '' : ', $message'})';
}

/// Checks the destination folders of a dialog, and keeps the partial files it made until their jobs take them
class WriteProbe {
  WriteProbe(this._writer, {this.maxFolders = 50, LibraryPathRules? rules})
    : _rules = rules ?? LibraryPathRules.thisComputer();

  final SafeWriter _writer;
  final LibraryPathRules _rules;

  /// How many distinct folders are checked at most; the others are checked by their jobs
  final int maxFolders;

  final _results = <String, ProbeResult>{};
  final _parts = <String, PartFile>{};
  // The distinct folders checked: checking one again (Change, Next to the original) does not count twice
  final _checked = <String>{};

  /// The check of [folder], null while it was not checked
  ProbeResult? resultOf(String folder) => _results[_key(folder)];

  /// Checks each folder of [requests] that was not checked yet, through its first request; the result of every folder
  /// of [requests], by the folder as given
  Future<Map<String, ProbeResult>> check(Iterable<ProbeRequest> requests) async {
    final results = <String, ProbeResult>{};
    for (final request in requests) {
      final key = _key(request.folder);
      var result = _results[key];
      if (result == null) {
        if (!_checked.contains(key) && _checked.length >= maxFolders) {
          result = const ProbeResult(ProbeStatus.notChecked);
        } else {
          _checked.add(key);
          result = await _check(request);
        }
        _results[key] = result;
      }
      results[request.folder] = result;
    }
    return results;
  }

  Future<ProbeResult> _check(ProbeRequest request) async {
    final files = _writer.files;
    try {
      if (!await files.isFolder(request.folder)) {
        if (!request.createFolder) {
          return const ProbeResult(ProbeStatus.missing);
        }
        await files.createFolder(request.folder);
      }
      _parts[request.jobId] = await _writer.createPart(request.folder, request.finalName);
      return const ProbeResult(ProbeStatus.ready);
    } on CreatorWriteException catch (error) {
      return ProbeResult(_statusOf(error.failure), message: error.message);
    } on FileSystemException catch (error) {
      return ProbeResult(_statusOf(writeFailureOf(error)), message: error.message);
    }
  }

  static ProbeStatus _statusOf(WriteFailure failure) => switch (failure) {
    WriteFailure.readOnly => ProbeStatus.readOnly,
    WriteFailure.diskFull => ProbeStatus.diskFull,
    WriteFailure.folderMissing => ProbeStatus.missing,
    WriteFailure.other => ProbeStatus.failed,
  };

  /// The jobs that hold a partial file of the check now
  Iterable<String> get jobsWithParts => _parts.keys;

  /// The partial file made for [jobId], which its job now owns; null when the check made none for it
  PartFile? take(String jobId) => _parts.remove(jobId);

  /// Deletes the partial file made for each job that no longer writes to the folder of it ([folders] gives the folder
  /// of each job now), so that the next check of that folder goes through another job
  Future<void> keepOnly(Map<String, String> folders) async {
    for (final jobId in List.of(_parts.keys)) {
      final part = _parts[jobId]!;
      final folder = folders[jobId];
      if (folder == null || _key(folder) != _key(part.folder)) {
        _parts.remove(jobId);
        _results.remove(_key(part.folder));
        await _writer.discard(part);
      }
    }
  }

  /// Forgets the checks of the folders that refused, so that the next check tries them again (the user asked for the
  /// folder of the original again, or freed some space)
  void forgetRefusals() => _results.removeWhere((_, result) => !result.accepted);

  /// Deletes every partial file no job took: the dialog closed without launching
  Future<void> release() async {
    final left = List.of(_parts.values);
    _parts.clear();
    for (final part in left) {
      await _writer.discard(part);
    }
  }

  String _key(String folder) {
    final normalized = _rules.context.normalize(_rules.context.absolute(folder));
    return _rules.caseFold ? normalized.toLowerCase() : normalized;
  }
}
