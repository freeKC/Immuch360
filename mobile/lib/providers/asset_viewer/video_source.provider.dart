// Whether the device decodes a video, asked to the native decoder check (VideoDecoderApi.canDecode) with what the probe
// of its file found (see SphericalProbeService), and which file of a server video the players load: the original or
// the server's transcoded stream, see chooseVideoSource.

import 'dart:math' as math;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('VideoSource');

/// The original of the video [videoId] on the server, as the camera recorded it
String serverOriginalVideoUrl(String videoId) => '${Store.get(StoreKey.serverEndpoint)}/assets/$videoId/original';

/// The transcoded stream of the video [videoId] on the server, the original itself when nothing was transcoded
String serverTranscodedVideoUrl(String videoId) =>
    '${Store.get(StoreKey.serverEndpoint)}/assets/$videoId/video/playback';

/// Where a video plays from: [url], and [fallbackUrl], the server's transcoded stream that a native player switches
/// to by itself when it cannot play the original, null when there is none to switch to (a file on the device plays as
/// it is, and a copy beyond the decoders is never one). [notice] is what to tell the user about the file chosen, null
/// for nothing. With a [refusal], nothing the server has decodes on the device: the player says so at once rather than
/// load [url], which it tries only when the user asks to play anyway. [copyBeyondDecoders] tells, while the original
/// plays, that the server's copy is beyond the decoders (the immersive viewer says it when it has to download the
/// original rather than stream the copy); null otherwise. [kind] is the file [url] is, and [hasCopy] whether the
/// server has a copy of its own to choose (false when its playback stream is the original itself), null when the choice
/// did not need to know (see [serverHasCopyProvider]).
class ChosenVideoSource {
  const ChosenVideoSource({
    required this.url,
    this.fallbackUrl,
    this.notice,
    this.refusal,
    this.copyBeyondDecoders,
    this.kind = VideoSourceKind.original,
    this.hasCopy,
  });

  final String url;
  final String? fallbackUrl;
  final VideoSourceNotice? notice;
  final VideoSourceRefusal? refusal;
  final VideoSourceNotice? copyBeyondDecoders;
  final VideoSourceKind kind;
  final bool? hasCopy;

  @override
  String toString() =>
      'ChosenVideoSource(url: $url, fallbackUrl: $fallbackUrl, notice: $notice, refusal: $refusal, '
      'copyBeyondDecoders: $copyBeyondDecoders)';
}

/// Asks the native decoder check whether the device decodes the video a probe describes, and keeps the answers in
/// memory: the decoders do not change while the app runs, and the videos of a library come in a few formats only.
///
/// [client] gives the client that asks the server for the size of a video and of its transcoded stream, see
/// [transcodeIsOriginal]; without one, the transcoded stream is taken for a file of its own. [probeTranscoded] reads
/// what the server's transcoded stream of a video declares (see SphericalProbeService.probeTranscoded); without it,
/// nothing is known of that stream, which then counts as one that may play.
class VideoSourceService {
  VideoSourceService(
    this._api, {
    this._client,
    this._probeTranscoded,
    this.timeout = const Duration(seconds: 2),
    this.sizeTimeout = const Duration(seconds: 5),
  });

  final VideoDecoderApi _api;
  final http.Client Function()? _client;
  final Future<SphericalProbe?> Function(String videoId)? _probeTranscoded;

  /// The largest frame, long side by short side, that every decoder takes whatever its codec: the server's copy of a
  /// video no larger than that, never larger than its original, plays without a look at it
  static const smallLongSide = 1920;
  static const smallShortSide = 1088;

  /// Longest wait for the decoder check
  final Duration timeout;

  /// Longest wait for the sizes of a video and of its transcoded stream
  final Duration sizeTimeout;

  final _verdicts = <String, DecodeVerdict>{};

  // Whether the transcoded stream of a video is its original, by video id
  final _transcodeIsOriginal = <String, bool>{};

  /// Whether the device decodes the video track [probe] describes, with its bit depth and its HDR transfer when the
  /// file tells them (they decide the 10 bit and HDR10 profiles a decoder must list). Null when the probe misses its
  /// codec or its frame size, and when the check fails or takes longer than [timeout]: the check is tried again next
  /// time.
  Future<DecodeVerdict?> verdict(SphericalProbe? probe) async {
    final codec = probe?.codec;
    final width = probe?.codedWidth;
    final height = probe?.codedHeight;
    if (probe == null || codec == null || width == null || height == null) {
      return null;
    }
    return _ask(
      codec: codec,
      codecs: probe.codecs,
      width: width,
      height: height,
      frameRate: probe.frameRate ?? 0,
      bitDepth: probe.bitDepth ?? 0,
      transfer: probe.transferCharacteristics ?? 0,
    );
  }

  /// Whether the device decodes two video streams of [codec] (with its RFC 6381 [codecs] when known) of [width] x
  /// [height] at [frameRate] and [bitDepth] at once, one decoder each: the two lenses of a raw 360° video whose plan
  /// has two tracks (two tracks of one file, or the two files of a split pair). On a phone, a refusal is worth a word
  /// before the player opens anyway; the native players fall back by themselves when the decoders fail. Null when the
  /// codec or the size is unknown, or when the check fails or takes longer than [timeout].
  Future<DecodeVerdict?> twoStreamVerdict({
    required String? codec,
    String? codecs,
    required int? width,
    required int? height,
    double? frameRate,
    int? bitDepth,
  }) async {
    if (codec == null || width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return _ask(
      codec: codec,
      codecs: codecs,
      width: width,
      height: height,
      frameRate: frameRate ?? 0,
      bitDepth: bitDepth ?? 0,
      transfer: 0,
      instances: 2,
    );
  }

  // Asks the decoder check, once per question
  Future<DecodeVerdict?> _ask({
    required String codec,
    required String? codecs,
    required int width,
    required int height,
    required double frameRate,
    required int bitDepth,
    required int transfer,
    int instances = 1,
  }) async {
    // The codec the codecs string names, which is another one for the HEVC base layer of a Dolby Vision track
    // without its own configuration (see SphericalProbe.codecs): the decoders are asked about that layer
    final asked = codecs?.split('.').first ?? codec;
    final streams = instances > 1 ? ' x$instances' : '';
    final key = '$asked $codecs ${width}x$height $frameRate $bitDepth $transfer$streams';
    final known = _verdicts[key];
    if (known != null) {
      return known;
    }
    try {
      final verdict = await _api
          .canDecode(asked, codecs, width, height, frameRate, bitDepth, transfer, instances: instances)
          .timeout(timeout);
      _log.fine('$key: $verdict');
      return _verdicts[key] = verdict;
    } catch (error) {
      _log.info('Could not check whether this device decodes $key: $error');
      return null;
    }
  }

  /// Whether the transcoded stream of the server video [videoId] is its original: the server serves the original
  /// there when it transcoded nothing (the transcoding settings left the video as it is, or the job has not run yet).
  /// Told by the sizes of the two files, one HEAD request each, kept in memory once both are known. False when a size
  /// is unknown: the request failed, took longer than [sizeTimeout], or the answer had no Content-Length.
  Future<bool> transcodeIsOriginal(String videoId) async {
    final known = _transcodeIsOriginal[videoId];
    if (known != null) {
      return known;
    }
    final client = _client;
    if (client == null) {
      return false;
    }
    try {
      final sizes = await Future.wait([
        _size(client(), serverOriginalVideoUrl(videoId)),
        _size(client(), serverTranscodedVideoUrl(videoId)),
      ]).timeout(sizeTimeout);
      final original = sizes[0];
      final transcoded = sizes[1];
      if (original == null || transcoded == null) {
        _log.info('No size for the original or the transcoded stream of $videoId: $original, $transcoded');
        return false;
      }
      _log.fine('$videoId: original of $original bytes, transcoded stream of $transcoded bytes');
      return _transcodeIsOriginal[videoId] = original == transcoded;
    } catch (error) {
      _log.info('Could not compare the original and the transcoded stream of $videoId: $error');
      return false;
    }
  }

  // The size of the file at [url] as the server tells it, null when it does not
  static Future<int?> _size(http.Client client, String url) async {
    final response = await client.head(Uri.parse(url));
    if (response.statusCode != 200) {
      return null;
    }
    return int.tryParse(response.headers['content-length'] ?? '');
  }

  /// The refusal of the decoder check when the 360° player would get nothing it decodes from [source], the choice of
  /// [serverSource] for the server video [videoId]: the device cannot decode the original ([probe]), the source is the
  /// original, or the transcoded stream when the server transcoded nothing (so the original again: under the default
  /// transcode policy of the server an H.264 file is never transcoded, whatever its size), and there is no stream to
  /// fall back to. Asked whatever the policy, unlike [serverSource]. Null when it would play, or may: no probe, no
  /// verdict, a decodable original, a smaller stream.
  Future<DecodeVerdict?> refusedServerStream({
    required String videoId,
    required SphericalProbe? probe,
    required ChosenVideoSource source,
  }) async {
    if (source.fallbackUrl != null) {
      return null;
    }
    final verdict = await this.verdict(probe);
    if (verdict == null || verdict.supported) {
      return null;
    }
    final playsOriginal = source.url == serverOriginalVideoUrl(videoId) || await transcodeIsOriginal(videoId);
    return playsOriginal ? verdict : null;
  }

  /// Which file of the server video [videoId] plays under [policy], decodability first (see [chooseVideoSource]):
  /// the original, of which [probe] tells what its file declares (or [probeOriginal] reads it, only once its verdict
  /// matters: the policy did not read the file and the copy does not decode), against the server's transcoded stream,
  /// which the server may not have (see [transcodeIsOriginal]) and of which [probeTranscoded] tells, each checked
  /// against the decoders of the device. [forced] is the file the user chose for this video in its details.
  /// [wantsFallback]: the player switches to the copy by itself when the original fails (the immersive viewer), so the
  /// copy is looked at even when the original plays, never to be a fallback that does not decode. [width] x [height]
  /// is the frame of the video as the server records it: within [smallLongSide] x [smallShortSide], the copy is not
  /// looked at, every decoder taking it.
  Future<ChosenVideoSource> serverSource({
    required String videoId,
    required VideoSourcePolicy policy,
    SphericalProbe? probe,
    Future<SphericalProbe?> Function()? probeOriginal,
    VideoSourceKind? forced,
    bool wantsFallback = false,
    int? width,
    int? height,
  }) async {
    var original = VideoCandidate.of(probe, policy.readsTheFile ? await verdict(probe) : null);
    final forcedKind = forced ?? (policy == VideoSourcePolicy.alwaysOriginal ? VideoSourceKind.original : null);
    // The copy matters when it may play or be the fallback; under the original forced it plays no part
    final copyMatters = switch (forcedKind) {
      VideoSourceKind.original => false,
      VideoSourceKind.transcoded => true,
      null => policy == VideoSourcePolicy.alwaysTranscoded || wantsFallback || original.undecodable,
    };
    final small =
        width != null &&
        height != null &&
        math.max(width, height) <= smallLongSide &&
        math.min(width, height) <= smallShortSide;
    VideoCandidate? copy = VideoCandidate.unknown;
    final copyAsked = copyMatters && !(small && !original.undecodable);
    if (copyAsked) {
      copy = await transcodeIsOriginal(videoId) ? null : await _copyCandidate(videoId);
    }
    // The original read late, under "Always the transcoded stream", once the choice depends on it
    if (original.verdict == null && forcedKind == null && (copy == null || copy.undecodable)) {
      final late = probe ?? await probeOriginal?.call();
      original = VideoCandidate.of(late, await verdict(late));
    }
    final choice = chooseVideoSource(policy: policy, original: original, copy: copy, forced: forced);
    if (original.verdict != null || copy?.verdict != null) {
      _log.info(
        '$videoId under $policy${forced != null ? ', $forced forced' : ''}: $choice; original $original, copy $copy',
      );
    }
    final transcoded = serverTranscodedVideoUrl(videoId);
    final playsOriginal = choice.kind == VideoSourceKind.original;
    return ChosenVideoSource(
      url: playsOriginal ? serverOriginalVideoUrl(videoId) : transcoded,
      // A fallback only when the server has a transcoded stream: otherwise a native player would reload the same
      // original on an error and say it switched
      fallbackUrl: choice.allowFallback && copy != null && !await transcodeIsOriginal(videoId) ? transcoded : null,
      notice: choice.notice,
      refusal: choice.refusal,
      copyBeyondDecoders: playsOriginal && copy != null && copy.undecodable ? copy.notice(.originalOverCopy) : null,
      kind: choice.kind,
      // Not asked when the choice did not depend on it: what the fallback asked, if anything, else unknown
      hasCopy: copyAsked ? copy != null : _knownHasCopy(videoId),
    );
  }

  // Whether the server has a copy of [videoId] of its own, when its sizes were compared already; null otherwise
  bool? _knownHasCopy(String videoId) => switch (_transcodeIsOriginal[videoId]) {
    null => null,
    final same => !same,
  };

  // What the server's transcoded stream of [videoId] declares, with the verdict of the decoder check on it
  Future<VideoCandidate> _copyCandidate(String videoId) async {
    final read = _probeTranscoded;
    if (read == null) {
      return VideoCandidate.unknown;
    }
    final probe = await read(videoId);
    return VideoCandidate.of(probe, await verdict(probe));
  }
}

/// Whether the server has a copy of its own of the video [videoId] (see [VideoSourceService.transcodeIsOriginal]):
/// asked by the details of a video whose player chose without knowing, so that they never offer a copy the server does
/// not have, nor call its original the server's copy. True when the sizes cannot be compared, as for the players.
final serverHasCopyProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, videoId) async => !await ref.watch(videoSourceServiceProvider).transcodeIsOriginal(videoId),
);

/// Client of the requests for the sizes of a video and of its transcoded stream: the app's shared client, with its
/// native SSL setup and the headers of the server. Tests replace it.
final videoSourceClientProvider = Provider<http.Client>((_) => NetworkRepository.client);

/// The decoder check of the players. Its answers last as long as the app.
final videoSourceServiceProvider = Provider<VideoSourceService>(
  (ref) => VideoSourceService(
    ref.watch(videoDecoderApiProvider),
    // Read when a size is asked, which only a look at the transcoded stream does: the shared client exists once the
    // app has a server
    client: () => ref.read(videoSourceClientProvider),
    probeTranscoded: (videoId) => ref.read(sphericalProbeServiceProvider).probeTranscoded(videoId),
  ),
);

/// The file the user chose for a server video in its details ("Play the original", "Play the server's copy"), by video
/// id, for as long as the app runs: the in-app player and the immersive viewer play it over the settings and the
/// decoder check (see [chooseVideoSource]), with a word when it is beyond the decoders
class VideoSourceOverrides extends StateNotifier<Map<String, VideoSourceKind>> {
  VideoSourceOverrides() : super(const {});

  /// The file forced for [videoId], null when the choice is the app's
  VideoSourceKind? of(String videoId) => state[videoId];

  /// Plays [kind] for [videoId] from now on
  void force(String videoId, VideoSourceKind kind) => state = {...state, videoId: kind};
}

final videoSourceOverridesProvider = StateNotifierProvider<VideoSourceOverrides, Map<String, VideoSourceKind>>(
  (_) => VideoSourceOverrides(),
);

/// What the in-app player chose last for each server video it played, by video id: the details of the video tell
/// which file plays and offer the other one
class ChosenVideoSources extends StateNotifier<Map<String, ChosenVideoSource>> {
  ChosenVideoSources() : super(const {});

  /// Past this many videos, the ones chosen first are forgotten
  static const maxEntries = 100;

  void record(String videoId, ChosenVideoSource source) {
    final next = {...state}
      ..remove(videoId)
      ..[videoId] = source;
    while (next.length > maxEntries) {
      next.remove(next.keys.first);
    }
    state = next;
  }
}

final chosenVideoSourcesProvider = StateNotifierProvider<ChosenVideoSources, Map<String, ChosenVideoSource>>(
  (_) => ChosenVideoSources(),
);

/// What the details of a video tell about its file: what its probe found, whether the device decodes it, and its bit
/// rate, each null when unknown
typedef VideoDecodeDetails = ({SphericalProbe? probe, DecodeVerdict? verdict, VideoBitRate? bitRate});

/// The file of [asset], a video, as its details show it: from the probe of the copy on the device when there is one,
/// else of the original on the server. Its bit rate comes from the probe, else from the size of the file over the
/// duration of the asset.
final videoDecodeDetailsProvider = FutureProvider.autoDispose.family<VideoDecodeDetails, BaseAsset>((ref, asset) async {
  final probes = ref.watch(sphericalProbeServiceProvider);
  final sources = ref.watch(videoSourceServiceProvider);
  final probe = await probes.probe(asset);
  final verdict = await sources.verdict(probe);
  // The size of the file is only asked when the probe tells no rate: for a file on the device, the system may have to
  // fetch it
  final fileSize = videoBitRateOf(probe: probe) == null ? await _fileSizeOf(ref, asset) : null;
  final bitRate = videoBitRateOf(probe: probe, fileSize: fileSize, durationMs: asset.durationMs);
  return (probe: probe, verdict: verdict, bitRate: bitRate);
});

// The size in bytes of the file of [asset]: as the server or the database records it, else of its copy on the device;
// null when neither tells
Future<int?> _fileSizeOf(Ref ref, BaseAsset asset) async {
  try {
    final recorded = (await ref.watch(assetExifProvider(asset).future))?.fileSize;
    if (recorded != null && recorded > 0) {
      return recorded;
    }
    final localId = asset.localId;
    if (localId == null) {
      return null;
    }
    return await (await ref.read(storageRepositoryProvider).getFileForAsset(localId))?.length();
  } catch (error) {
    _log.fine('No file size for ${asset.name}: $error');
    return null;
  }
}

/// Every video decoder of the device, for the decoders page of the settings
final videoDecodersProvider = FutureProvider.autoDispose<List<DecoderInfo>>(
  (ref) => ref.watch(videoDecoderApiProvider).listDecoders(),
);

/// Translated messages of the native 360° and Spatial 2.5D players about the decoders, under the keys they read
/// (VideoDecoders.LABEL_SWITCHED and the others on Android): the switch to the transcoded stream when the device cannot
/// decode the original, the original that plays anyway with nothing to switch to, and the errors of a decoder that
/// refused the video or gave no picture, and of a video that does not load. "{codec}", "{width}" and "{height}" stay
/// as they are: the players fill them in from the track they could not decode.
Map<String, String> videoSourceLabels(Translations t) => {
  'sourceSwitched': t.video_source_switched(codec: '{codec}', width: '{width}', height: '{height}'),
  'sourceUndecodable': t.video_source_undecodable(codec: '{codec}', width: '{width}', height: '{height}'),
  'errorDecoder': t.video_error_decoder(codec: '{codec}', width: '{width}', height: '{height}'),
  'errorNoFrame': t.video_error_no_frame(codec: '{codec}', width: '{width}', height: '{height}'),
  'errorStalled': t.video_error_stalled,
};

extension VideoSourceNoticeMessage on VideoSourceNotice {
  /// The message that tells the user about the file chosen, in the words of [t]
  String message(Translations t) {
    final w = '$width';
    final h = '$height';
    return switch (kind) {
      VideoSourceNoticeKind.switched => t.video_source_copy_plays(codec: codec, width: w, height: h),
      VideoSourceNoticeKind.originalForced => t.video_source_original_forced(codec: codec, width: w, height: h),
      VideoSourceNoticeKind.originalOverCopy => t.video_source_original_plays(codec: codec, width: w, height: h),
      VideoSourceNoticeKind.copyForced => t.video_source_copy_forced(codec: codec, width: w, height: h),
      VideoSourceNoticeKind.beyondDecoders => t.video_source_undecodable(codec: codec, width: w, height: h),
    };
  }
}

extension VideoSourceRefusalMessage on VideoSourceRefusal {
  /// Why the video does not play and what to change in Immich, in the words of [t]: the frame beyond the largest one
  /// the device decodes in that codec, or no decoder at all for the codec
  String message(Translations t) => hasDecoder
      ? t.video_cannot_decode(
          codec: codec,
          width: '$width',
          height: '$height',
          maxWidth: '$maxWidth',
          maxHeight: '$maxHeight',
        )
      : '${t.video_failed_no_decoder(codec: codec)}\n${t.video_failed_server_hint}';
}
