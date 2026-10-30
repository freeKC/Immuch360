// The versions of the photos of a share put next to their originals (FreeKC, 30 October 2026: "Make 3D (AI)" on a
// photo of a share, the result next to the original on the share when it takes files and the user said yes for that
// folder). The queue makes each version on this computer, in a folder of its own among the copies of the AI, as it
// makes any other one (its partial file, its rename, the times of its steps). Once a job is done, the publisher writes
// its file next to the original through the writer of the shares (share_writer.dart): under its name, or the first
// free "name (n)" when that is taken, never over a file; with the batch that skips a name taken, nothing is written.
// The file then leaves this computer, with its folder, once no job of the queue reads it any more: a panorama stays
// until its 3D version, chained after it, was made from it. A version the share refuses at that moment (the share
// gone, a folder that turned read only, a disk full) is kept in the folder of my choice of the dialog, with the words
// of the share; nothing is lost. A job that failed or was cancelled writes nothing, and keeps its folder for Retry. The
// pages of the share read the folder again once a version is there (shareFolderChangesProvider): its tile and its
// badge show, and the Versions of its original.

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/library/scene_glb_export.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SharePublisher');

/// Where the version of a job goes on a share
class ShareVersionTarget {
  const ShareVersionTarget({
    required this.folder,
    required this.fallbackFolder,
    this.skipWhenTaken = false,
    this.withGlb = false,
  });

  /// The folder of its original on the share
  final ShareFolder folder;

  /// The folder of my choice of the dialog, on this computer: the version stays there when the share refuses it
  final String fallbackFolder;

  /// The batch skips a name taken ("If the name is taken: Skip"): nothing is written then
  final bool skipWhenTaken;

  /// A 3D scene whose .glb copy was asked for ("Also save a .glb copy"): the copy, made next to it here
  /// (scene_glb_export.dart), goes to the share with it
  final bool withGlb;
}

/// Where the version of a job is on its way to the share
enum SharePublishState {
  /// Its job is not done yet
  waiting,

  /// Being written on the share
  writing,

  /// On the share
  saved,

  /// Not written: its name is taken on the share and the batch skips such files
  skipped,

  /// The share refused it: kept in the folder of my choice on this computer
  keptHere;

  /// Nothing more happens to it
  bool get isEnded => this == saved || this == skipped || this == keptHere;
}

/// The version of a job and the share it goes to
class SharePublish {
  const SharePublish(
    this.target, {
    this.state = SharePublishState.waiting,
    this.path,
    this.keptPath,
    this.failure,
    this.message,
    this.glbPath,
  });

  final ShareVersionTarget target;
  final SharePublishState state;

  /// The file on the share once saved, a path of the share
  final String? path;

  /// The file on this computer when the share refused it
  final String? keptPath;

  /// Why the share refused it, and its words
  final ShareWriteFailure? failure;
  final String? message;

  /// The .glb copy of a 3D scene on the share, or kept with it on this computer
  final String? glbPath;

  /// The file on the share as the dialog names its folder: "\\\\nas\\photos\\2024\\salon_3D.jpg"
  String? get shown => _shown(path);

  /// The .glb copy of a 3D scene on the share, named so
  String? get glbShown => keptPath == null ? _shown(glbPath) : glbPath;

  String? _shown(String? written) {
    if (written == null) {
      return null;
    }
    final label = target.folder.label;
    final separator = label.startsWith(r'\\') ? r'\' : '/';
    final folder = label.endsWith(separator) ? label.substring(0, label.length - 1) : label;
    return '$folder$separator${p.posix.basename(written)}';
  }

  SharePublish _copy({
    required SharePublishState state,
    String? path,
    String? keptPath,
    ShareWriteFailure? failure,
    String? message,
    String? glbPath,
  }) => SharePublish(
    target,
    state: state,
    path: path,
    keptPath: keptPath,
    failure: failure,
    message: message,
    glbPath: glbPath,
  );
}

/// The folders of the shares the app put a version in, by "sourceId:/folder", each with the number of times: the pages
/// of the share read the folder again when it changes
class ShareFolderChanges extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  /// A file was put in [folder] of the share [sourceId]
  void changed(String sourceId, String folder) {
    final key = shareFolderChangeKey(sourceId, folder);
    state = {...state, key: (state[key] ?? 0) + 1};
  }
}

/// The key of [folder] of the share [sourceId] in shareFolderChangesProvider
String shareFolderChangeKey(String sourceId, String folder) => '$sourceId:${shareFolderOfPath('$folder/x')}';

final shareFolderChangesProvider = NotifierProvider<ShareFolderChanges, Map<String, int>>(ShareFolderChanges.new);

/// See the top of this file: the versions followed, by the id of their job
class SharePublisher extends Notifier<Map<String, SharePublish>> {
  /// The jobs whose file is being written on a share
  final _writing = <String>{};

  /// The folders of this computer the versions were made in, deleted once no job reads them
  final _staged = <String>{};

  @override
  Map<String, SharePublish> build() {
    ref.listen(conversionQueueProvider, (_, queue) => _onQueue(queue));
    // The .glb copy of a scene, made once the scene is done, goes with it
    ref.listen(sceneGlbCopiesProvider, (_, _) => _onQueue(ref.read(conversionQueueProvider)));
    return const {};
  }

  /// Follows the jobs of [targets], each with the folder of the share its version goes to
  void follow(Map<String, ShareVersionTarget> targets) {
    if (targets.isEmpty) {
      return;
    }
    state = {...state, for (final MapEntry(:key, :value) in targets.entries) key: SharePublish(value)};
    _onQueue(ref.read(conversionQueueProvider));
  }

  void _onQueue(ConversionQueueState queue) {
    for (final MapEntry(key: id, value: publish) in state.entries) {
      final job = queue.byId(id);
      final folder = job?.target?.folder;
      if (folder != null) {
        _staged.add(folder);
      }
      if (job == null || publish.state != SharePublishState.waiting || _writing.contains(id)) {
        continue;
      }
      final written = job.writtenPath;
      if (job.state == ConversionState.done && written != null) {
        String? glb;
        if (publish.target.withGlb && job.kind == ConversionKind.sceneFromPhoto) {
          final copy = ref.read(sceneGlbCopiesProvider)[id];
          if (copy == null) {
            // Its .glb copy is being written next to it
            continue;
          }
          glb = copy.path;
        }
        _writing.add(id);
        unawaited(_publish(id, written, publish.target, glb: glb));
      }
    }
    _cleanUp(queue);
  }

  Future<void> _publish(String id, String written, ShareVersionTarget target, {String? glb}) async {
    _set(id, (publish) => publish._copy(state: SharePublishState.writing));
    final file = File(written);
    final name = p.basename(written);
    late SharePublish Function(SharePublish publish) ended;
    ShareWriter? writer;
    try {
      writer = await ref.read(shareWriterOpenerProvider)(target.folder.sourceId);
      if (writer == null) {
        throw const ShareWriteException(ShareWriteFailure.readOnly, 'This share takes no file');
      }
      final path = await publishShareVersion(
        writer,
        file,
        folder: target.folder.path,
        name: name,
        skipWhenTaken: target.skipWhenTaken,
      );
      if (path == null) {
        ended = (publish) => publish._copy(state: SharePublishState.skipped);
      } else {
        _log.info('$name is on its share as $path');
        // Its .glb copy beside it, under the name it has here or the first free one
        final glbPath = glb == null
            ? null
            : await publishShareVersion(writer, File(glb), folder: target.folder.path, name: p.basename(glb));
        ended = (publish) => publish._copy(state: SharePublishState.saved, path: path, glbPath: glbPath);
      }
    } catch (error) {
      final failure = error is ShareWriteException ? error.failure : ShareWriteFailure.failed;
      final message = error is ShareWriteException ? error.message : '$error';
      _log.warning('$name could not be written on its share, kept on this computer: $error');
      String? kept;
      String? keptGlb;
      try {
        // Copied: a 3D version chained after a panorama still reads it here
        final folder = await Directory(target.fallbackFolder).create(recursive: true);
        kept = (await copyIntoFolder(file, folder, name)).path;
        if (glb != null) {
          keptGlb = (await copyIntoFolder(File(glb), folder, p.basename(glb))).path;
        }
      } catch (copyError) {
        _log.severe('$name could not be kept in ${target.fallbackFolder} either: $copyError');
      }
      ended = (publish) => publish._copy(
        state: SharePublishState.keptHere,
        keptPath: kept,
        failure: failure,
        message: message,
        glbPath: keptGlb,
      );
    } finally {
      try {
        await writer?.close();
      } catch (error) {
        _log.fine('The writer of the share did not close cleanly: $error');
      }
    }
    // Told once everything of it is done here, its folder deleted when no job reads it any more
    _writing.remove(id);
    _set(id, ended);
    _cleanUp(ref.read(conversionQueueProvider));
    if (state[id]?.state == SharePublishState.saved) {
      ref.read(shareFolderChangesProvider.notifier).changed(target.folder.sourceId, target.folder.path);
    }
  }

  /// Deletes each folder a version was made in once every job that writes there or reads from it ended and its
  /// version left: written on the share, skipped, or kept in the folder of my choice. A folder of a job that failed
  /// or was cancelled stays for Retry, until the queue forgets the job (Clear finished) or the next start
  /// (cleanUpAiCopiesAtStart).
  void _cleanUp(ConversionQueueState queue) {
    for (final folder in List.of(_staged)) {
      final jobs = [
        for (final job in queue.jobs)
          if (job.target?.folder == folder) job,
      ];
      // Skipped, a job made nothing there; done, its version has left once its publish ended
      final done = jobs.every(
        (job) =>
            job.state == ConversionState.skipped ||
            (job.state == ConversionState.done && (state[job.id]?.state.isEnded ?? true) && !_writing.contains(job.id)),
      );
      final forgotten = jobs.isEmpty;
      if (!done && !forgotten) {
        continue;
      }
      _staged.remove(folder);
      try {
        final directory = Directory(folder);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      } on FileSystemException catch (error) {
        _log.fine('The folder of a version stays until the next start: ${error.message}');
      }
    }
  }

  void _set(String id, SharePublish Function(SharePublish publish) change) {
    final publish = state[id];
    if (publish != null) {
      state = {...state, id: change(publish)};
    }
  }
}

final sharePublisherProvider = NotifierProvider<SharePublisher, Map<String, SharePublish>>(SharePublisher.new);
