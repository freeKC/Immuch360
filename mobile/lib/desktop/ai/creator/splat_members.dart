// The photos, or the video, of a splat scene as the engine reads them (plan 2026-11-01, lot SP5): each source of the
// queue (a file of this computer read in place, an original of the server copied to the temporary folder, a file of
// a share) as a SplatMember, read when the engine gets to it and released as soon as the engine has its bytes. The
// queue (lot SP6) makes them from the selection, with the time each was taken (the library's, or the server's) that
// orders them, and for an asset of the server its checksum, which a Retry from the poses compares without downloading
// the original again (SplatMemberSum).

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

/// A [ConversionSource] as a member of a splat scene; [sha1] is the checksum the server gives for its asset (base64)
class SourceSplatMember implements SplatMember, SplatMemberSum {
  SourceSplatMember(this.source, {this.taken, this.camera, String? sha1}) : knownSha1 = sha1;

  final ConversionSource source;

  @override
  final String? knownSha1;

  @override
  final DateTime? taken;

  @override
  final String? camera;

  @override
  String get name => source.name;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) => source.prepare(cancel);

  @override
  Future<void> release() => source.release();
}
