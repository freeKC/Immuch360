// The screens of the AV2 videos (lot AD5: av2_gate.dart, av2_decoding.dart, the "Video decoding" line) wired to their
// playback (lot AD3: av2_playback.dart) in the app of the computers (lot AD6 of store/m2/av2-2026-11-02/
// plan-2026-11-02.md, sections 1.2 to 1.4):
// - the gate reads the format of a video from the probe of the companion, which the player's open then takes rather
//   than probing again (Av2Playbacks.probe);
// - the speed this computer measured for that format comes from the decoder measures the playback keeps, so that the
//   notice of a computer too slow (decision D2) comes before the player, with its numbers;
// - "Play anyway" tells the playback, whose own check of the measure would stop the player otherwise;
// - activeAv2Decoding follows the session the player plays, for the "Video decoding" line of the details
//   (Av2DecodingFollower, made with the app's playbacks in desktop_video_view.dart);
// - the thumbnails of the library take the frame of an AV2 video through the app's frame grabber, which opens it
//   through its decoder once it is installed (VideoThumbnailGrabber; set with the app's playbacks too), and those of
//   the shares once the decoder is installed (av2DecoderInstalledProvider).

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';

/// The overrides of the AV2 videos in the root scope of the computers (desktop_overrides.dart)
List<Override> av2AppOverrides() => [
  av2ProbeProvider.overrideWith(
    (ref) =>
        (video) => av2ProbeFormat(
          ref.read(av2PlaybacksProvider),
          video,
          shareOf: (sourceId) => ref.read(networkConnectionsProvider).fileSystem(sourceId),
        ),
  ),
  av2SpeedProvider.overrideWith((ref) {
    final playbacks = ref.read(av2PlaybacksProvider);
    return (format) => av2MeasuredSpeed(format, load: playbacks.loadMeasure, decoder: playbacks.decoderVersion);
  }),
  av2PlayAnywayProvider.overrideWith(
    (ref) =>
        (video) => ref.read(av2PlaybacksProvider).playAnyway(video.key),
  ),
];

/// The format of [video] the gate shows: the probe of the companion by [playbacks] (kept for the player's open of the
/// video), its file of this computer or of the share [shareOf] gives
Future<Av2VideoFormat> av2ProbeFormat(
  Av2Playbacks playbacks,
  Av2VideoRef video, {
  required Future<NetworkFileSystem> Function(String sourceId) shareOf,
}) async {
  final path = video.path;
  final bytes = path != null ? Av2Bytes.file(path) : Av2Bytes.share(await shareOf(video.sourceId!), video.sharePath!);
  return av2FormatOfProbe(video.head, await playbacks.probe(bytes));
}

/// What the gate knows of a video whose head is [head] once the companion probed it ([probe]): the size of its first
/// picture and its depth, the frame rate of its container (the measures of speed are kept with it), and the words of
/// what this version does not play, as the playback refuses it (Av2FormatRefused)
Av2VideoFormat av2FormatOfProbe(Av2Head head, Av2Probe probe) {
  final ofHead = Av2VideoFormat.ofHead(head);
  final plays = probe.playable && probe.width != null && probe.height != null && probe.bits != null;
  return Av2VideoFormat(
    width: probe.width ?? ofHead.width,
    height: probe.height ?? ofHead.height,
    frameRate: ofHead.frameRate,
    bitDepth: probe.bits,
    refusedFormat: plays ? null : probe.refusal ?? probe.format,
  );
}

/// The last speed this computer measured for [format] with the decoder [decoder], from [load] (the decoder measures,
/// DecoderMeasureStore.av2Speed); null when it never played that format, or the format is not fully known
Future<Av2Speed?> av2MeasuredSpeed(
  Av2VideoFormat format, {
  required Future<Av2SpeedMeasure?> Function(Av2Format format, String decoder)? load,
  required String decoder,
}) async {
  final width = format.width;
  final height = format.height;
  final bits = format.bitDepth;
  if (load == null || width == null || height == null || bits == null) {
    return null;
  }
  final measure = await load(Av2Format(width: width, height: height, bits: bits, frameRate: format.frameRate), decoder);
  return measure == null ? null : Av2Speed(decodedFps: measure.fps, neededFps: format.frameRate);
}
