// The stabilisation of the raw 360° videos in the immersive viewer of the Meta Quest (issue 14, lot d3): the table of
// a video's motion track, built in a background isolate while it plays and handed to the viewer, which turns it inside
// its stitch frame by frame (ImmersiveStabilization.kt). The same delivery as the phone's 360° player
// (openStabilizedSphericalVideo), keyed by URL so that previous and next work, with the settings of a headset
// (StabilizationOptions.headset: the heading smoothed over 2 s, at most 30 degrees a second).

import 'dart:async';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_stabilization.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ImmersiveStabilization');

/// Tells the immersive viewer about the stabilisation of each raw video it shows (see ImmersiveApi.setStabilization),
/// where the viewer stabilises ([supported], see videoStabilizationSupportedProvider) with the setting [enabled]: the
/// raw video of a plan whose camera wrote a motion track the app reads, in a file read at any position (see
/// [rawVideoHasReadableTrack]), is announced before the viewer shows it (its button shows while the track is read), and
/// its table, built by [build] meanwhile, reaches the viewer when ready, the playback never waiting for it. Another raw
/// video is told it has none (the button hides). The build stops once the viewer shows another media in its place,
/// closes or does not open ([session]). A failure to tell the viewer never stops the playback: the log keeps it.
class ImmersiveStabilization {
  ImmersiveStabilization({
    required this.api,
    required this.session,
    required this.supported,
    required this.enabled,
    this.build = buildRawStabilizationInIsolate,
    this.options = StabilizationOptions.headset,
  });

  /// Reads the services and the settings from the providers. Call it before the first await of an opener.
  factory ImmersiveStabilization.read(WidgetRef ref) => ImmersiveStabilization(
    api: ref.read(immersiveApiProvider),
    session: ref.read(immersiveSessionProvider),
    supported: ref.read(videoStabilizationSupportedProvider),
    enabled: ref.read(appConfigProvider).viewer.stabilizeVideos,
    build: ref.read(rawStabilizationBuilderProvider),
  );

  final ImmersiveApi api;
  final ImmersiveSession session;

  /// Whether the viewer of this device stabilises
  final bool supported;

  /// The setting "Stabilise with the camera's gyroscope" when the viewer opened; the switch of the viewer wins once
  /// pressed
  final bool enabled;
  final RawStabilizationBuilder build;
  final StabilizationOptions options;

  /// The delivery of the table of the last media shown, for the tests; null when none is built
  Future<StabilizationTable?>? lastDelivery;

  /// Shows [request] with [show] (ImmersiveApi.open, or showAdjacent whose answer [shown] reads: false when the viewer
  /// did not show it), told about its stabilisation first. Returns what [show] returned.
  Future<T> around<T>(ImmersiveRequest request, Future<T> Function() show, {bool Function(T result)? shown}) async {
    final plan = request.rawPlan;
    if (!supported || !request.isVideo || plan == null) {
      return show();
    }
    final candidate = RawVideoStabilizer(
      send: _send,
      url: request.url,
      enabled: enabled,
      plan: plan,
      build: build,
      options: options,
    );
    final stabilizer = candidate.applies ? candidate : null;
    if (stabilizer != null) {
      await stabilizer.announce();
    } else {
      await tellStabilizationSettingWith(_send, request.url, enabled: enabled);
    }
    final result = await show();
    if (stabilizer == null) {
      return result;
    }
    if (shown != null && !shown(result)) {
      // The viewer kept the media it showed: this one's table is not built
      stabilizer.cancel();
      return result;
    }
    // The media shown before goes away: the build of its table stops
    session.mediaReplaced();
    session.whenMediaGone(stabilizer.cancel);
    // Not awaited: the video plays meanwhile, the table reaches the viewer when ready
    final delivery = stabilizer.deliver();
    lastDelivery = delivery;
    unawaited(
      delivery.catchError((Object error, StackTrace stackTrace) {
        _log.warning('The stabilisation table of ${request.title} was not delivered', error, stackTrace);
        return null;
      }),
    );
    return result;
  }

  // The API looked up at each call, so that a test's fake answers as it was set up then
  Future<void> _send(
    String url,
    bool enabled,
    bool hasTrack,
    Int64List? presentationTimesUs,
    Float64List? corrections,
    String? summary,
  ) => api.setStabilization(url, enabled, hasTrack, presentationTimesUs, corrections, summary);
}
