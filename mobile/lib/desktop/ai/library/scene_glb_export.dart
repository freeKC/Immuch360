// The .glb of a 3D scene, for other 3D apps (design-final 2026-10-27, section 8.2, point 5): the binary glTF a photo of
// Immuch360 carries after its JPEG, checked by its length and its SHA-256 (scene_container.dart), written alone to a
// file of its own. "Export for other 3D apps (.glb)" of the Versions writes it where the user says (the save dialog of
// the system, next to the scene at first); "Also save a .glb copy" (desktop_ai.json, off by default) writes it next to
// each scene the conversions make, "salon_scene3D.glb", the first free "name (n).glb" when that name is taken. An
// export is not a version: the library scans no .glb, and neither the scene nor its original is ever written to. The
// file is written beside its place first, then renamed onto its name, so that a failure leaves nothing half written.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SceneGlbExport');

/// Why the .glb of a scene was not written
enum SceneGlbProblem {
  /// The file carries no packet of a 3D scene of Immuch360
  notScene,

  /// Its packet names a scene the file does not hold whole (saved again by another program, cut short)
  missing,

  /// The .glb could not be written there
  writeFailed,
}

class SceneGlbException implements Exception {
  const SceneGlbException(this.problem, [this.message]);

  final SceneGlbProblem problem;

  /// The words of the system, for a write that failed
  final String? message;

  @override
  String toString() => 'SceneGlbException(${problem.name}${message == null ? '' : ': $message'})';
}

/// The words of a .glb that was not written
String sceneGlbProblemText(Translations t, SceneGlbException error) => switch (error.problem) {
  SceneGlbProblem.notScene => t.ai_immersive_scene_not_ours,
  SceneGlbProblem.missing => t.ai_immersive_scene_missing,
  SceneGlbProblem.writeFailed => t.ai_immersive_glb_failed(message: error.message ?? ''),
};

/// The binary glTF the photo at [scenePath] carries, its length and its sum checked; throws a [SceneGlbException]
Future<Uint8List> sceneGlbOf(String scenePath) async {
  final Uint8List bytes;
  try {
    bytes = await File(scenePath).readAsBytes();
  } on FileSystemException catch (error) {
    throw SceneGlbException(SceneGlbProblem.missing, error.osError?.message ?? error.message);
  }
  final xmp = ImmersiveXmp.findIn(bytes);
  if (xmp is! SceneXmp) {
    throw const SceneGlbException(SceneGlbProblem.notScene);
  }
  final glb = sceneBytesOf(bytes, xmp);
  if (glb == null) {
    throw const SceneGlbException(SceneGlbProblem.missing);
  }
  // A copy of its own: the view on the whole file would keep the photo in memory as long as the scene
  return Uint8List.fromList(glb);
}

/// Writes [glb] to [target]: a partial file beside it, renamed onto it once whole (a file the user chose to replace in
/// the save dialog is replaced then). Never onto [scenePath] itself. Throws a [SceneGlbException].
Future<void> writeSceneGlb(Uint8List glb, String target, {required String scenePath}) async {
  if (_samePath(target, scenePath)) {
    throw const SceneGlbException(SceneGlbProblem.writeFailed, 'the scene itself');
  }
  final part = File(p.join(p.dirname(target), '.${p.basename(target)}.part'));
  try {
    await part.writeAsBytes(glb, flush: true);
    await part.rename(target);
  } on FileSystemException catch (error) {
    try {
      if (part.existsSync()) {
        await part.delete();
      }
    } on FileSystemException catch (failure) {
      _log.warning('The partial file ${part.path} stays: ${failure.message}');
    }
    throw SceneGlbException(SceneGlbProblem.writeFailed, error.osError?.message ?? error.message);
  }
}

/// "salon_scene3D.glb" next to "salon_scene3D.jpg", or the first free "salon_scene3D (n).glb"
String freeGlbPathNextTo(String scenePath) {
  final stem = p.join(p.dirname(scenePath), p.basenameWithoutExtension(scenePath));
  var candidate = '$stem.glb';
  for (var count = 1; File(candidate).existsSync() || Directory(candidate).existsSync(); count++) {
    candidate = '$stem ($count).glb';
  }
  return candidate;
}

bool _samePath(String a, String b) {
  final left = p.normalize(p.absolute(a));
  final right = p.normalize(p.absolute(b));
  return Platform.isWindows || Platform.isMacOS ? left.toLowerCase() == right.toLowerCase() : left == right;
}

/// "Export for other 3D apps (.glb)": the save dialog of the system, next to the scene at [scenePath] at first, then the
/// .glb written there; what came of it said by a message
Future<void> exportSceneGlb(BuildContext context, String scenePath) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final String? chosen;
  try {
    chosen = await filePickers.saveLocation(
      suggestedName: '${p.basenameWithoutExtension(scenePath)}.glb',
      initialDirectory: p.dirname(scenePath),
      typeLabel: 'glTF',
      extensions: const ['glb'],
    );
  } on Exception catch (error) {
    _log.warning('The save dialog failed: $error');
    return;
  }
  if (chosen == null) {
    return;
  }
  final target = p.extension(chosen).toLowerCase() == '.glb' ? chosen : '$chosen.glb';
  try {
    await writeSceneGlb(await sceneGlbOf(scenePath), target, scenePath: scenePath);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(t.ai_immersive_glb_saved(folder: p.dirname(target), name: p.basename(target))),
      ),
    );
  } on SceneGlbException catch (error) {
    _log.warning('The scene of $scenePath was not exported: $error');
    messenger?.showSnackBar(SnackBar(content: Text(sceneGlbProblemText(t, error))));
  }
}

/// What "Also save a .glb copy" did for the scene of a job: where its copy is, or why it was not written
class SceneGlbCopy {
  const SceneGlbCopy.written(String this.path) : error = null;

  const SceneGlbCopy.failed(SceneGlbException this.error) : path = null;

  final String? path;
  final SceneGlbException? error;
}

/// The .glb copies of the scenes of the jobs the dialog asked them for, by the id of the job, each written once its
/// scene is made (a job retried after a failure too)
class SceneGlbCopies extends Notifier<Map<String, SceneGlbCopy>> {
  final _wanted = <String>{};

  @override
  Map<String, SceneGlbCopy> build() {
    ref.listen(conversionQueueProvider, (_, queue) => _copyMade(queue));
    return const {};
  }

  /// Writes the .glb copy of the scene of each job of [ids] once it is made
  void follow(Iterable<String> ids) {
    _wanted.addAll(ids);
    _copyMade(ref.read(conversionQueueProvider));
  }

  void _copyMade(ConversionQueueState queue) {
    for (final job in queue.jobs) {
      if (!_wanted.contains(job.id)) {
        continue;
      }
      final written = job.writtenPath;
      if (job.state == ConversionState.done && written != null && job.kind == ConversionKind.sceneFromPhoto) {
        _wanted.remove(job.id);
        unawaited(_copy(job.id, written));
      } else if (job.state == ConversionState.skipped || job.state == ConversionState.done) {
        // Nothing made: a version with the same settings kept, a name taken and skipped
        _wanted.remove(job.id);
      }
    }
  }

  Future<void> _copy(String id, String scenePath) async {
    SceneGlbCopy copy;
    try {
      final glb = await sceneGlbOf(scenePath);
      final target = freeGlbPathNextTo(scenePath);
      await writeSceneGlb(glb, target, scenePath: scenePath);
      copy = SceneGlbCopy.written(target);
    } on SceneGlbException catch (error) {
      _log.warning('No .glb copy of $scenePath: $error');
      copy = SceneGlbCopy.failed(error);
    }
    state = {...state, id: copy};
  }
}

final sceneGlbCopiesProvider = NotifierProvider<SceneGlbCopies, Map<String, SceneGlbCopy>>(SceneGlbCopies.new);
