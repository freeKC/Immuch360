// The writer of the versions as the queue relies on it (SafeWriter.commit of lot A5b, lot C3 for the kinds), for the
// tests of the queue: a .part with a dot name next to the target, renamed at the end, "name (1)" when the name is
// taken; Replace takes a file of the folder of the .part only, and only when it still carries our XMP of the kind of
// the job with a DerivativeId.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

class FakeConversionOutput implements ConversionOutput {
  final begun = <String>[];
  final discarded = <String>[];

  /// What each finish was asked, and the original it was given
  final finished = <(AiWhenExists, String?)>[];
  final originals = <ImmersiveSource>[];

  /// The jobs each finish was given
  final jobs = <ConversionJob>[];
  ImmersiveErrorCode? failFinish;

  /// The failure of the rename of the job of each name of original, once
  final failFinishOf = <String, ImmersiveErrorCode>{};

  @override
  Future<String> begin(ConversionJob job) async {
    final target = job.target!;
    final path = p.join(target.folder, '.${target.fileName}.$pid-${begun.length + 1}.immuch360.part');
    File(path).writeAsBytesSync(const []);
    begun.add(path);
    return path;
  }

  @override
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required ImmersiveSource original,
    required AiWhenExists whenExists,
    String? replaceName,
  }) async {
    finished.add((whenExists, replaceName));
    originals.add(original);
    jobs.add(job);
    final code = failFinishOf.remove(job.source.name) ?? failFinish;
    if (code != null) {
      throw ConversionException(code, 'Scripted failure of the rename');
    }
    final target = job.target!;
    final named = p.join(
      p.dirname(partPath),
      whenExists == AiWhenExists.replace ? replaceName ?? target.fileName : target.fileName,
    );
    if (File(named).existsSync()) {
      if (whenExists == AiWhenExists.skip) {
        File(partPath).deleteSync();
        return ConversionSaved(path: named, outcome: ConversionSaveOutcome.skipped);
      }
      final xmp = ImmersiveXmp.findIn(File(named).readAsBytesSync());
      final id = xmp?.derivativeId;
      if (whenExists == AiWhenExists.replace && xmp?.kind == job.kind.output && id != null && id.trim().isNotEmpty) {
        File(partPath).renameSync(named);
        return ConversionSaved(path: named, outcome: ConversionSaveOutcome.replaced);
      }
    }
    var path = target.path;
    for (var n = 1; File(path).existsSync(); n++) {
      path = p.join(
        target.folder,
        '${p.basenameWithoutExtension(target.fileName)} ($n)${p.extension(target.fileName)}',
      );
    }
    File(partPath).renameSync(path);
    return ConversionSaved(path: path, outcome: ConversionSaveOutcome.saved);
  }

  @override
  Future<void> discard(String partPath) async {
    discarded.add(partPath);
    final file = File(partPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
