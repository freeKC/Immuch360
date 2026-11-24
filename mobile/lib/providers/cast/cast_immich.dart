// Google Cast of an Immich photo or video (release 52): what the phone reads before casting it, and how the relay
// reads it from the server. The relay asks the server with the app's own HTTP client, which carries the session
// itself (network.repository.dart): no session key ever goes into an address the Cast device sees, unlike Immich's
// own Cast (gcast.service.dart), which put one there.
//
// A photo goes as the server's JPEG of full size, oriented by the server: HEIC, TIFF and RAW originals included. A
// server with no full size image of it (the default: Immich makes them only when image.fullsize.enabled is on)
// redirects to its preview; the relay follows no redirect, so the phone asks once beforehand (a HEAD) and gives the
// relay the address the server redirects to, when it is the same server and the same asset's thumbnail; else the
// preview itself. A redirect elsewhere is never followed: the session and the custom headers go with every request.
// A 360° photo goes flat, with a note.
//
// A video: the probe of its original's first bytes gives its codecs (spherical_probe.dart), the format check of the
// device says whether it should play; when it should not, the version the server converted for playback
// (video/playback) goes in its place when the server made one: the sizes of the two answers differ then. Immich
// converts to H.264 and AAC by default, which every Cast device decodes; a server set to another codec is not seen
// from the phone, the check takes the default.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('CastPlay');

/// What the cast of an Immich asset needs from the app, replaced in the tests
class CastImmichEnvironment {
  const CastImmichEnvironment({required this.serverEndpoint, required this.send, required this.probe});

  /// The server's endpoint, "https://photos.example/api"
  final String? Function() serverEndpoint;

  /// A request through the app's client, which adds the session
  final Future<http.StreamedResponse> Function(http.BaseRequest request) send;

  /// The probe of a video's original, null when it fails
  final Future<SphericalProbe?> Function(PlayOnImmichAsset asset) probe;
}

final castImmichEnvironmentProvider = Provider<CastImmichEnvironment>((ref) {
  return CastImmichEnvironment(
    serverEndpoint: () => Store.tryGet(StoreKey.serverEndpoint),
    send: (request) {
      request.headers.addAll(ApiService.getRequestHeaders());
      return NetworkRepository.client.send(request);
    },
    probe: (asset) async {
      final base = asset.asset;
      return base == null ? null : ref.read(sphericalProbeServiceProvider).probe(base);
    },
  );
});

/// The codec name the format check knows for a four character code of an MP4 sample entry
String? castCodecOfFourCc(String? fourCc) => switch (fourCc?.trim().toLowerCase()) {
  null || '' => null,
  'avc1' || 'avc3' => 'h264',
  'hvc1' || 'hev1' || 'dvh1' || 'dvhe' => 'hevc',
  'av01' => 'av1',
  'vp09' => 'vp9',
  'vp08' => 'vp8',
  'mp4a' => 'aac',
  'ac-3' => 'ac3',
  'ec-3' => 'eac3',
  'opus' => 'opus',
  'flac' || 'fla1' => 'flac',
  'alac' => 'alac',
  'lpcm' || 'sowt' || 'twos' || 'in24' || 'fl32' => 'pcm',
  '.mp3' => 'mp3',
  final other => other,
};

/// The format of an Immich video's original: the container from its file name, the codecs and the size from [probe]
CastFilmFormat castFormatOfProbe(String? fileName, SphericalProbe? probe) {
  final name = fileName ?? '';
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? null : name.substring(dot + 1).toLowerCase();
  final sound = probe?.tracks.where((track) => track.handlerType == 'soun').firstOrNull;
  return CastFilmFormat(
    container: switch (extension) {
      'mov' || 'qt' => 'mov',
      'mp4' || 'm4v' => 'mp4',
      null => null,
      final other => other,
    },
    videoCodec: castCodecOfFourCc(probe?.codec),
    audioCodec: castCodecOfFourCc(sound?.codec),
    width: probe?.codedWidth,
    height: probe?.codedHeight,
  );
}

/// What Immich's default conversion gives: H.264 and AAC in MP4, at most 720p by default
const castImmichConvertedFormat = CastFilmFormat(container: 'mp4', videoCodec: 'h264', audioCodec: 'aac');

/// The address of [path] of the asset [id] on the server of [endpoint]
Uri castImmichUrl(String endpoint, String id, String path, [Map<String, String>? query]) {
  final base = Uri.parse(endpoint);
  return base.replace(
    path: '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}/assets/$id/$path',
    queryParameters: query,
  );
}

/// The relay's request of [url] through [send]
CastRelayUpstream castImmichUpstream(CastImmichEnvironment environment, Uri url) => (method, headers) {
  final request = http.Request(method, url)
    ..followRedirects = false
    ..headers.addAll(headers);
  return environment.send(request);
};

Future<int?> _lengthOf(CastImmichEnvironment environment, Uri url) async {
  try {
    final answer = await environment
        .send(http.Request('HEAD', url)..followRedirects = false)
        .timeout(const Duration(seconds: 8));
    await answer.stream.drain<void>();
    return answer.statusCode == 200 ? answer.contentLength : null;
  } catch (error) {
    _log.fine('Cast: no length of a version (${error.runtimeType})');
    return null;
  }
}

/// The address a redirect of the photo [from] goes to when it stays on the same server and on the thumbnail of the same
/// asset [id] of [endpoint]; null for anything else (another host, port or scheme, another path)
Uri? castImmichPhotoRedirect(Uri from, String endpoint, String id, String? location) {
  if (location == null || location.isEmpty) {
    return null;
  }
  final Uri resolved;
  try {
    resolved = from.resolve(location);
  } on FormatException {
    return null;
  }
  final thumbnail = castImmichUrl(endpoint, id, 'thumbnail');
  if (resolved.scheme != from.scheme ||
      resolved.host.toLowerCase() != from.host.toLowerCase() ||
      resolved.port != from.port ||
      resolved.userInfo.isNotEmpty ||
      resolved.path != thumbnail.path) {
    return null;
  }
  return resolved.removeFragment();
}

/// The address of the photo [id] the relay reads: its full size JPEG when the server has one, else where the server
/// redirects (its preview), else the preview
Future<Uri> castImmichPhotoUrl(CastImmichEnvironment environment, String endpoint, String id) async {
  final fullsize = castImmichUrl(endpoint, id, 'thumbnail', {'size': 'fullsize', 'edited': 'true'});
  final preview = castImmichUrl(endpoint, id, 'thumbnail', {'size': 'preview', 'edited': 'true'});
  try {
    final answer = await environment
        .send(http.Request('HEAD', fullsize)..followRedirects = false)
        .timeout(const Duration(seconds: 8));
    await answer.stream.drain<void>();
    if (answer.statusCode == 200) {
      return fullsize;
    }
    if (const {301, 302, 303, 307, 308}.contains(answer.statusCode)) {
      return castImmichPhotoRedirect(fullsize, endpoint, id, answer.headers['location']) ?? preview;
    }
  } catch (error) {
    _log.fine('Cast: the full size photo could not be checked (${error.runtimeType})');
  }
  return preview;
}

/// What the cast of the Immich asset of [request] reads beforehand; null for a request of another source
Future<CastFilmInfo?> readImmichCastInfo(CastImmichEnvironment environment, PlayOnRequest request) async {
  final asset = request.immich;
  final endpoint = environment.serverEndpoint();
  if (asset == null || endpoint == null || endpoint.isEmpty) {
    return null;
  }
  final title = asset.fileName ?? request.title ?? '';
  if (!asset.video) {
    return CastFilmInfo(
      title: title,
      photo: true,
      format: const CastFilmFormat(),
      contentType: 'image/jpeg',
      upstream: castImmichUpstream(environment, await castImmichPhotoUrl(environment, endpoint, asset.id)),
      flat360: asset.projection.isSphere,
      fileName: asset.fileName,
    );
  }
  final original = castImmichUrl(endpoint, asset.id, 'original');
  final playback = castImmichUrl(endpoint, asset.id, 'video/playback');
  final probe = await environment.probe(asset).catchError((Object _) => null);
  final lengths = await Future.wait([_lengthOf(environment, original), _lengthOf(environment, playback)]);
  final converted = lengths[0] != null && lengths[1] != null && lengths[0] != lengths[1];
  return CastFilmInfo(
    title: title,
    format: castFormatOfProbe(asset.fileName, probe),
    durationMs: asset.durationMs,
    fileName: asset.fileName,
    contentType: 'video/mp4',
    upstream: castImmichUpstream(environment, original),
    convertedUpstream: converted ? castImmichUpstream(environment, playback) : null,
    convertedFormat: converted ? castImmichConvertedFormat : null,
    flat360: asset.projection.isSphere,
  );
}
