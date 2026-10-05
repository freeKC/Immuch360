// Whether the device decodes a video, asked to the native decoder check (VideoDecoderApi.canDecode) with what the probe
// of its file found (see SphericalProbeService), and which file of a server video the players load: the original or
// the server's transcoded stream, see chooseVideoSource.

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
/// it is). [notice] is what to tell the user about the file chosen, null for nothing.
class ChosenVideoSource {
  const ChosenVideoSource({required this.url, this.fallbackUrl, this.notice});

  final String url;
  final String? fallbackUrl;
  final VideoSourceNotice? notice;

  @override
  String toString() => 'ChosenVideoSource(url: $url, fallbackUrl: $fallbackUrl, notice: $notice)';
}

/// Asks the native decoder check whether the device decodes the video a probe describes, and keeps the answers in
/// memory: the decoders do not change while the app runs, and the videos of a library come in a few formats only.
///
/// [client] gives the client that asks the server for the size of a video and of its transcoded stream, see
/// [transcodeIsOriginal]; without one, the transcoded stream is taken for a file of its own.
class VideoSourceService {
  VideoSourceService(
    this._api, {
    this._client,
    this.timeout = const Duration(seconds: 2),
    this.sizeTimeout = const Duration(seconds: 5),
  });

  final VideoDecoderApi _api;
  final http.Client Function()? _client;

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

  /// Which file of the server video [videoId] plays under [policy] (see [chooseVideoSource]), with [probe], what its
  /// file declares, checked against the decoders of the device. Before it switches to the transcoded stream, it makes
  /// sure the server has one (see [transcodeIsOriginal]): otherwise the original plays, with a word that the device
  /// may not decode it rather than one of a switch that would not happen.
  Future<ChosenVideoSource> serverSource({
    required String videoId,
    required VideoSourcePolicy policy,
    SphericalProbe? probe,
  }) async {
    final verdict = policy.readsTheFile ? await this.verdict(probe) : null;
    // Only a switch away from the original asks the server: the other choices play the same whatever its stream is
    final switches = policy == VideoSourcePolicy.preferOriginalWithinDecoder && verdict?.supported == false;
    final hasTranscode = !switches || !await transcodeIsOriginal(videoId);
    final choice = chooseVideoSource(policy: policy, probe: probe, verdict: verdict, hasTranscode: hasTranscode);
    if (verdict != null) {
      _log.info('$videoId under $policy: $choice, ${verdict.reason ?? 'no reason given'}');
    }
    final transcoded = serverTranscodedVideoUrl(videoId);
    // A fallback only when the server has a transcoded stream: otherwise a native player would reload the same
    // original on an error and say it switched
    final allowFallback = choice.allowFallback && !await transcodeIsOriginal(videoId);
    return ChosenVideoSource(
      url: choice.kind == VideoSourceKind.original ? serverOriginalVideoUrl(videoId) : transcoded,
      fallbackUrl: allowFallback ? transcoded : null,
      notice: choice.notice,
    );
  }
}

/// Client of the requests for the sizes of a video and of its transcoded stream: the app's shared client, with its
/// native SSL setup and the headers of the server. Tests replace it.
final videoSourceClientProvider = Provider<http.Client>((_) => NetworkRepository.client);

/// The decoder check of the players. Its answers last as long as the app.
final videoSourceServiceProvider = Provider<VideoSourceService>(
  (ref) => VideoSourceService(
    ref.watch(videoDecoderApiProvider),
    // Read when a size is asked, which only a switch to the transcoded stream does: the shared client exists once
    // the app has a server
    client: () => ref.read(videoSourceClientProvider),
  ),
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

/// Translated message of the native 360° and Spatial 2.5D players when they switch to the transcoded stream by
/// themselves, the device being unable to decode the original, under the key they read (VideoDecoders.LABEL_SWITCHED
/// on Android). "{codec}", "{width}" and "{height}" stay as they are: the players fill them in from the track they
/// could not decode.
Map<String, String> videoSourceLabels(Translations t) => {
  'sourceSwitched': t.video_source_switched(codec: '{codec}', width: '{width}', height: '{height}'),
};

extension VideoSourceNoticeMessage on VideoSourceNotice {
  /// The message that tells the user about the file chosen, in the words of [t]
  String message(Translations t) => switch (kind) {
    VideoSourceNoticeKind.switched => t.video_source_switched(codec: codec, width: '$width', height: '$height'),
    VideoSourceNoticeKind.originalForced => t.video_source_original_forced(
      codec: codec,
      width: '$width',
      height: '$height',
    ),
  };
}
