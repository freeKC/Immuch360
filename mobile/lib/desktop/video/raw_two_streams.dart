// Raw files of 360° cameras whose lenses come in two streams, on the computers (design 2.5, plan 2.2 step 2d): two
// video tracks of one file (Insta360 X4 and later, the EAC tracks of a GoPro .360, a DJI .osv) or one file per lens
// (an Insta360 X3 recording split in two). One mpv core decodes both and lays them side by side with lavfi-complex
// "[vid1] [vid2] hstack [vo]"; the second file of a pair joins as an external track (external-files). FFmpeg's filter
// graph pairs the frames of the two streams by their time stamps, so the seam does not tear as two players would.
// Renderer C then stitches the stacked frame as it stitches a side by side file: the lens regions of the plan are
// rewritten into the frame mpv draws (rawProjectionFor).
//
// Whether a computer keeps up with two streams is measured on the playback (raw_two_stream_switch.dart). When it does
// not, or when a stream fails, the phones' fallback chain applies in their order and with their messages
// (RawPlaybackPlanner.kt of the Android app): one lens with half of the sphere black, the server's transcoded stream,
// then, as design 2.5 adds for the computers, the camera's low resolution LRV copy where one sits next to the file,
// and last the frame as the camera recorded it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';

/// A decoded stream of a raw file, as its rawProjection JSON lists it: a video track of the file opened ([file] 0) or
/// of the other file of a split pair ([file] 1)
@immutable
class RawStreamTrack {
  const RawStreamTrack({
    required this.file,
    required this.videoTrack,
    this.width,
    this.height,
    this.codec,
    this.codecs,
  });

  final int file;

  /// Index among the video tracks of its file
  final int videoTrack;
  final int? width;
  final int? height;

  /// Four character code of the sample entry ("hvc1", "avc1") and its RFC 6381 string
  final String? codec;
  final String? codecs;

  int get pixels => (width ?? 0) * (height ?? 0);

  @override
  String toString() => 'RawStreamTrack(file $file, video track $videoTrack, ${width}x$height, $codec)';
}

/// What the rawProjection JSON (RawVideoPlan.toNativeJson, version 2) says about the streams of a raw file
@immutable
class RawStreams {
  const RawStreams._(this.json, this.eac, this.layout, this.tracks, this.secondUrl, this.secondFallbackUrl);

  /// The streams of [json]. Throws a [FormatException] for a JSON whose tracks cannot be read.
  factory RawStreams.fromJson(Map<String, Object?> json) {
    final list = switch (json['tracks']) {
      final List<Object?> tracks when tracks.isNotEmpty && tracks.length <= 2 => tracks,
      _ => throw const FormatException('rawProjection: tracks'),
    };
    int? whole(Object? value) => value is num ? value.toInt() : null;
    final tracks = [
      for (final item in list)
        if (item is Map<String, Object?> && whole(item['file']) != null && whole(item['videoTrack']) != null)
          RawStreamTrack(
            file: whole(item['file'])!,
            videoTrack: whole(item['videoTrack'])!,
            width: whole(item['width']),
            height: whole(item['height']),
            codec: item['codec'] as String?,
            codecs: item['codecs'] as String?,
          )
        else
          throw const FormatException('rawProjection: track'),
    ];
    final layout = json['layout'];
    if (layout is! String) {
      throw const FormatException('rawProjection: layout');
    }
    final secondUrl = json['secondUrl'];
    final secondFallbackUrl = json['secondFallbackUrl'];
    return RawStreams._(
      json,
      json['kind'] == 'eacGoPro',
      layout,
      tracks,
      secondUrl is String && secondUrl.isNotEmpty ? secondUrl : null,
      secondFallbackUrl is String && secondFallbackUrl.isNotEmpty ? secondFallbackUrl : null,
    );
  }

  final Map<String, Object?> json;

  /// The two EAC tracks of a GoPro, rather than a fisheye pair
  final bool eac;

  /// "sideBySide", "twoTracks" or "twoFiles"
  final String layout;
  final List<RawStreamTrack> tracks;

  /// The other file of a split pair, and its transcoded stream
  final String? secondUrl;
  final String? secondFallbackUrl;

  bool get twoStreams => tracks.length >= 2;

  bool get twoFiles => layout == 'twoFiles';

  /// The larger of the streams: what the decoder checks and the measures are about
  RawStreamTrack get largest => tracks.reduce((a, b) => b.pixels > a.pixels ? b : a);

  /// hstack needs frames of one height. Unknown heights are tried: the graph fails then, and the one lens step follows.
  bool get stackable {
    if (!twoStreams) {
      return false;
    }
    final heights = {for (final track in tracks) track.height};
    return heights.length == 1 || heights.contains(null);
  }

  /// The stream one lens mode decodes, as the phones choose it (RawProjection.primaryStream): the stream of the lens
  /// that looks most to the front of the view, or for a GoPro the track of the face that does
  int get primaryStream {
    int textureOf(Object? item) => item is Map<String, Object?> && item['texture'] is num
        ? (item['texture']! as num).toInt().clamp(0, tracks.length - 1)
        : 0;
    if (eac) {
      final rotation = _numbers(json['viewToCamera'], 9);
      final faces = json['faces'];
      if (rotation == null || faces is! List<Object?>) {
        return 0;
      }
      // The camera direction of the view's forward (0, 0, 1): the third column of the row major matrix
      final forward = [rotation[2], rotation[5], rotation[8]];
      Object? best;
      var bestDot = double.negativeInfinity;
      for (final face in faces) {
        final axis = face is Map<String, Object?> ? _numbers(face['forward'], 3) : null;
        if (axis == null) {
          continue;
        }
        final dot = axis[0] * forward[0] + axis[1] * forward[1] + axis[2] * forward[2];
        if (dot > bestDot) {
          bestDot = dot;
          best = face;
        }
      }
      return textureOf(best);
    }
    final lenses = json['lenses'];
    if (lenses is! List<Object?>) {
      return 0;
    }
    Object? best;
    var bestZ = double.negativeInfinity;
    for (final lens in lenses) {
      final rotation = lens is Map<String, Object?> ? _numbers(lens['viewToLens'], 9) : null;
      // The z of the lens frame along the view's forward: the lens facing the front of the view
      if (rotation != null && rotation[8] > bestZ) {
        bestZ = rotation[8];
        best = lens;
      }
    }
    return textureOf(best);
  }

  /// The stream of the file opened, for one lens when the other file cannot be read
  int get streamOfFirstFile => tracks.indexWhere((track) => track.file == 0).clamp(0, tracks.length - 1);

  /// The file one lens of [stream] plays from: [url], or the other file of a pair
  String urlOfStream(int stream, String url) =>
      twoFiles && tracks[stream].file == 1 && secondUrl != null ? secondUrl! : url;

  /// mpv's video track id of [stream] in the file that plays it alone (vid, 1 for the first video track)
  int videoTrackAlone(int stream) => tracks[stream].videoTrack + 1;

  /// mpv's video track id of [stream] with both streams loaded: the tracks of the file opened, then those of the
  /// external file. The file opened of a split pair holds one video track: the resolver takes a file for one lens of a
  /// pair only when it has a single square video track (RawVideoResolver).
  int videoTrackStacked(int stream) {
    final track = tracks[stream];
    return track.file == 0 ? track.videoTrack + 1 : 1 + track.videoTrack + 1;
  }

  /// The lavfi-complex graph that stacks the two streams in the order of the JSON's tracks, the order the textures of
  /// the plan count them in
  String get hstackGraph => '[vid${videoTrackStacked(0)}] [vid${videoTrackStacked(1)}] hstack [vo]';

  @override
  String toString() => 'RawStreams(${eac ? 'EAC' : 'fisheye'}, $layout, $tracks)';
}

List<double>? _numbers(Object? value, int length) {
  if (value is! List<Object?> || value.length != length || value.any((item) => item is! num)) {
    return null;
  }
  return [for (final item in value) (item! as num).toDouble()];
}

/// What the frame mpv draws holds: some of the JSON's streams side by side, in that order, at their own widths (both
/// stacked by hstack, or one alone); or the two lenses side by side in one frame, lens i in its half i, as a side by
/// side file of the camera has them and as its LRV copy has them
@immutable
class RawFrame {
  const RawFrame.streams(this.streams) : lensesSideBySide = false;

  const RawFrame.lensesSideBySide() : streams = const [0], lensesSideBySide = true;

  final List<int> streams;
  final bool lensesSideBySide;

  @override
  bool operator ==(Object other) =>
      other is RawFrame && other.lensesSideBySide == lensesSideBySide && listEquals(other.streams, streams);

  @override
  int get hashCode => Object.hash(lensesSideBySide, Object.hashAll(streams));

  @override
  String toString() => lensesSideBySide ? 'RawFrame(lenses side by side)' : 'RawFrame(streams $streams)';
}

/// The rawProjection JSON of [raw] rewritten for [frame], with what the stitch pass needs beside it: [enabled], for
/// textures 0 and 1 of the rewritten JSON, whether that texture is decoded, and [streamsInFrame], the number of equal
/// parts the frame's width is cut in for the pass.
///
/// For a fisheye pair each lens moves to texture 0 and its region (x, y, width, height in fractions of its stream)
/// into the frame: a stream of width w at x0 in a frame of width W puts region [x, y, w', h] at
/// [(x0 + x w) / W, y, w' w / W, h]. Two streams of the same width stacked by hstack give the regions
/// [0.5 i, 0, 0.5, 1] of a side by side frame, as RawVideoPlan writes them for a side by side file. A lens whose
/// stream the frame does not hold goes to texture 1, which is off: half of the sphere stays black. The LRV copy holds
/// lens i in half i, whatever stream the original had it in.
///
/// The EAC tracks of a GoPro keep their textures: the pass cuts the frame in [streamsInFrame] equal parts (the two
/// tracks of a GoPro have one size), and one track alone becomes texture 0. Throws a [FormatException] for a JSON it
/// cannot rewrite.
@visibleForTesting
({Map<String, Object?> json, List<bool> enabled, int streamsInFrame}) rewriteRawRegions(
  RawStreams raw,
  RawFrame frame,
) {
  final json = Map<String, Object?>.of(raw.json);
  if (raw.eac) {
    if (frame.lensesSideBySide) {
      throw const FormatException('rawProjection: an EAC file has no side by side copy');
    }
    if (listEquals(frame.streams, const [0, 1])) {
      return (json: json, enabled: const [true, true], streamsInFrame: 2);
    }
    if (frame.streams.length != 1) {
      throw FormatException('rawProjection: EAC streams ${frame.streams}');
    }
    final shown = frame.streams.single;
    final faces = switch (json['faces']) {
      final List<Object?> list => list,
      _ => throw const FormatException('rawProjection: faces'),
    };
    json['faces'] = [
      for (final face in faces)
        if (face is Map<String, Object?>)
          {...face, 'texture': face['texture'] == shown ? 0 : 1}
        else
          throw const FormatException('rawProjection: face'),
    ];
    return (json: json, enabled: const [true, false], streamsInFrame: 1);
  }

  final lenses = switch (json['lenses']) {
    final List<Object?> list when list.length == 2 => list,
    _ => throw const FormatException('rawProjection: lenses'),
  };
  // Where each stream of the frame starts and how wide it is, in fractions of the frame's width
  final placements = <int, ({double x, double width})>{};
  if (!frame.lensesSideBySide) {
    final widths = [
      for (final stream in frame.streams)
        if (stream >= 0 && stream < raw.tracks.length)
          (raw.tracks[stream].width ?? 0) > 0 ? raw.tracks[stream].width!.toDouble() : 1.0
        else
          throw FormatException('rawProjection: no stream $stream'),
    ];
    // Unknown widths count as equal, as hstack of the streams of one camera gives
    final known = widths.every((width) => width > 1);
    final total = known ? widths.fold<double>(0, (sum, width) => sum + width) : widths.length.toDouble();
    var x = 0.0;
    for (final (i, stream) in frame.streams.indexed) {
      final width = (known ? widths[i] : 1.0) / total;
      placements[stream] = (x: x, width: width);
      x += width;
    }
  }
  var hidden = false;
  json['lenses'] = [
    for (final (i, lens) in lenses.indexed)
      if (lens is Map<String, Object?>)
        () {
          final region = _numbers(lens['region'], 4);
          final texture = lens['texture'];
          if (region == null || texture is! num) {
            throw const FormatException('rawProjection: lens region');
          }
          final placement = frame.lensesSideBySide ? (x: 0.5 * i, width: 0.5) : placements[texture.toInt()];
          if (placement == null) {
            hidden = true;
            return {...lens, 'texture': 1};
          }
          return {
            ...lens,
            'texture': 0,
            'region': [placement.x + region[0] * placement.width, region[1], region[2] * placement.width, region[3]],
          };
        }()
      else
        throw const FormatException('rawProjection: lens'),
  ];
  return (json: json, enabled: [true, !hidden], streamsInFrame: 1);
}

/// What renderer C draws for [raw] when mpv's frame holds [frame] (see [rewriteRawRegions]). Throws a
/// [FormatException] for a JSON it cannot draw.
PluginProjection rawProjectionFor(RawStreams raw, RawFrame frame) {
  final rewritten = rewriteRawRegions(raw, frame);
  return PluginProjection.raw(
    jsonEncode(rewritten.json),
    streamsEnabled: rewritten.enabled,
    streamsInFrame: rewritten.streamsInFrame,
  );
}

/// How the player decodes a raw file now, see the top of this file
enum RawMode {
  /// One frame holding both lenses: a side by side file, or the LRV copy
  stitched,

  /// Two streams stacked by hstack
  stacked,

  /// One of two streams, the other half of the sphere black
  oneLens,

  /// The frame as the camera recorded it, flat
  unstitched,
}

/// What the user is told about a step, in the phones' words where they have them (rawVideoLabels)
enum RawNotice {
  /// raw_video_one_lens_decoder: the computer does not keep up with two streams
  oneLensDecoder,

  /// raw_video_one_lens_file: the file of the other lens cannot be read
  oneLensFile,

  /// raw_video_low_resolution_copy: the camera's LRV copy plays
  lowResolutionCopy,

  /// raw_video_unstitched
  unstitched,
}

/// One step of the chain: [mode], the [streams] of the JSON in mpv's frame, the [url] the player opens and the
/// [externalUrl] it loads beside it (the other file of a pair), whether these are the server's transcoded streams
/// ([fromFallback]) or the LRV copy ([lowResolution]), mpv's [hwdec] for a stacked step (null: the switch chooses),
/// the [notice] to show and the [reason] for the logs
@immutable
class RawStep {
  const RawStep({
    required this.mode,
    this.streams = const [],
    required this.url,
    this.externalUrl,
    this.fromFallback = false,
    this.lowResolution = false,
    this.hwdec,
    this.notice,
    this.reason = '',
  });

  final RawMode mode;
  final List<int> streams;
  final String url;
  final String? externalUrl;
  final bool fromFallback;
  final bool lowResolution;
  final String? hwdec;
  final RawNotice? notice;
  final String reason;

  /// What mpv's frame holds, null when nothing is stitched
  RawFrame? get frame => switch (mode) {
    RawMode.unstitched => null,
    _ when lowResolution => const RawFrame.lensesSideBySide(),
    _ => RawFrame.streams(streams),
  };

  RawStep withHwdec(String hwdec) => RawStep(
    mode: mode,
    streams: streams,
    url: url,
    externalUrl: externalUrl,
    fromFallback: fromFallback,
    lowResolution: lowResolution,
    hwdec: hwdec,
    notice: notice,
    reason: reason,
  );

  @override
  bool operator ==(Object other) =>
      other is RawStep &&
      other.mode == mode &&
      listEquals(other.streams, streams) &&
      other.url == url &&
      other.externalUrl == externalUrl &&
      other.fromFallback == fromFallback &&
      other.lowResolution == lowResolution &&
      other.hwdec == hwdec &&
      other.notice == notice;

  @override
  int get hashCode =>
      Object.hash(mode, Object.hashAll(streams), url, externalUrl, fromFallback, lowResolution, hwdec, notice);

  // No URL here: a bridge URL carries its token, and a step goes to the logs
  @override
  String toString() =>
      'RawStep(${mode.name} $streams${externalUrl != null ? ' + external file' : ''}'
      '${fromFallback ? ', transcoded' : ''}${lowResolution ? ', LRV' : ''}${hwdec != null ? ', hwdec $hwdec' : ''}'
      '${notice != null ? ', ${notice!.name}' : ''}: $reason)';
}

/// What the switch of raw_two_stream_switch.dart says about two streams: mpv's [hwdec] to stack them with, null when
/// they are not to be stacked, and why
typedef TwoStreamChoice = ({String? hwdec, String reason});

/// The fallback chain of a raw file of two streams on the computers, pure so that every step is unit tested: the
/// steps of RawPlaybackPlanner.kt (two lenses, one lens, the transcoded streams, unstitched), with the LRV copy of
/// design 2.5 before the last one. [url] and [fallbackUrl] are what SphericalVideoApi.open gave: the original and the
/// server's transcoded stream; [lowResolutionUrl] the LRV copy next to the file, null when there is none.
class RawPlaybackChain {
  RawPlaybackChain({required this.raw, required this.url, this.fallbackUrl, this.lowResolutionUrl});

  final RawStreams raw;
  final String url;
  final String? fallbackUrl;

  /// Set once found: the player looks for it while the original opens, since only a failure needs it
  String? lowResolutionUrl;

  /// The step a video starts with: one frame for a side by side file; for two streams, stacked when [choice] gives a
  /// decoding path, else one lens with the phones' message
  RawStep initial(TwoStreamChoice choice) {
    if (!raw.twoStreams) {
      return RawStep(mode: RawMode.stitched, streams: const [0], url: url, reason: 'one frame');
    }
    if (raw.twoFiles && raw.secondUrl == null) {
      return _oneLens(raw.streamOfFirstFile, RawNotice.oneLensFile, 'no other file to load');
    }
    if (!raw.stackable) {
      return _oneLens(raw.primaryStream, RawNotice.oneLensDecoder, 'streams of two heights cannot be stacked');
    }
    final hwdec = choice.hwdec;
    if (hwdec == null) {
      return _oneLens(raw.primaryStream, RawNotice.oneLensDecoder, choice.reason);
    }
    return _stacked(url, raw.twoFiles ? raw.secondUrl : null, hwdec: hwdec, fromFallback: false, reason: choice.reason);
  }

  /// A stacked [step] measured too slow: stacked again through the next decoding path of [next], else one lens (or,
  /// on the transcoded streams already, the LRV copy, else the frame unstitched). Null for any other step.
  RawStep? afterSlowStack(RawStep step, TwoStreamChoice next) {
    if (step.mode != RawMode.stacked) {
      return null;
    }
    final hwdec = next.hwdec;
    if (hwdec != null && hwdec != step.hwdec) {
      return _stacked(step.url, step.externalUrl, hwdec: hwdec, fromFallback: step.fromFallback, reason: next.reason);
    }
    if (step.fromFallback) {
      return _lowResolution(step, 'the transcoded streams too slow stacked') ?? _unstitched('nothing else to stack');
    }
    return _oneLens(raw.primaryStream, RawNotice.oneLensDecoder, 'two streams too slow: ${next.reason}');
  }

  /// [step] failed to play (mpv could not open a file, decode, or build the graph). [externalReadable] says whether
  /// the other file of a stacked pair can be read: when it cannot, the file opened plays its own lens alone. Null when
  /// nothing is left: the error shows.
  RawStep? afterFailure(RawStep step, {bool externalReadable = true}) {
    switch (step.mode) {
      case RawMode.stitched when !step.lowResolution:
        // A side by side file: the route's own switch to the transcoded stream, as for any 360° video
        return null;
      case RawMode.stitched:
        return step.url == url ? null : _unstitched('the LRV copy failed');
      case RawMode.stacked when !step.fromFallback:
        if (raw.twoFiles && !externalReadable) {
          return _oneLens(raw.streamOfFirstFile, RawNotice.oneLensFile, 'the other file cannot be read');
        }
        return _oneLens(raw.primaryStream, RawNotice.oneLensDecoder, 'the two streams failed together');
      case RawMode.stacked:
        return _lowResolution(step, 'the transcoded streams failed') ?? _unstitched('the transcoded streams failed');
      case RawMode.oneLens:
        return _transcoded('the original lens failed') ??
            _lowResolution(step, 'the original lens failed, no transcoded streams') ??
            _unstitched('the original lens failed, no transcoded streams');
      case RawMode.unstitched when step.fromFallback:
        return _lowResolution(step, 'the transcoded stream failed');
      case RawMode.unstitched:
        return null;
    }
  }

  RawStep _oneLens(int stream, RawNotice notice, String reason) => RawStep(
    mode: RawMode.oneLens,
    streams: [stream],
    url: raw.urlOfStream(stream, url),
    notice: notice,
    reason: reason,
  );

  RawStep _stacked(
    String url,
    String? externalUrl, {
    required String? hwdec,
    required bool fromFallback,
    required String reason,
  }) => RawStep(
    mode: RawMode.stacked,
    streams: const [0, 1],
    url: url,
    externalUrl: externalUrl,
    fromFallback: fromFallback,
    hwdec: hwdec,
    reason: reason,
  );

  /// The server's transcoded streams, as the phones take them: both files of a pair stacked like the originals, else
  /// the one stream of a two track file unstitched (the server transcodes the first video track only)
  RawStep? _transcoded(String cause) {
    final fallback = fallbackUrl;
    final secondFallback = raw.secondFallbackUrl;
    if (raw.twoFiles && fallback != null && secondFallback != null) {
      return _stacked(
        fallback,
        secondFallback,
        hwdec: null,
        fromFallback: true,
        reason: '$cause, the transcoded streams of both files',
      );
    }
    if (!raw.twoFiles && fallback != null && fallback != url) {
      return RawStep(
        mode: RawMode.unstitched,
        url: fallback,
        fromFallback: true,
        notice: RawNotice.unstitched,
        reason: '$cause, the transcoded stream holds one lens',
      );
    }
    return null;
  }

  RawStep? _lowResolution(RawStep from, String cause) {
    final lrv = lowResolutionUrl;
    if (lrv == null || from.lowResolution || raw.eac) {
      return null;
    }
    return RawStep(
      mode: RawMode.stitched,
      streams: const [0],
      url: lrv,
      lowResolution: true,
      notice: RawNotice.lowResolutionCopy,
      reason: '$cause: the LRV copy',
    );
  }

  RawStep _unstitched(String reason) =>
      RawStep(mode: RawMode.unstitched, url: url, notice: RawNotice.unstitched, reason: reason);
}

// An Insta360 video: VID_20240908_193126_00_004.insv (lens 0 of a split pair, or a file of both lenses) or _10_ (lens
// 1); PRO_VID_ for the PureShot and HDR modes. A copy may carry a suffix such as "(1)" before the extension.
final _insta360Video = RegExp(r'^(?:PRO_)?VID_(\d{8}_\d{6})_[01]\d_(\d+)[^.]*\.insv$', caseSensitive: false);

/// The names the camera gives the LRV copy of the Insta360 video [name] (LRV_20240908_193126_11_004.lrv for the X3's
/// pair, _01_ for the files of both lenses), most likely first; none for another name
List<String> lowResolutionNamesOf(String name) {
  final match = _insta360Video.firstMatch(name);
  if (match == null) {
    return const [];
  }
  final stamp = match.group(1)!;
  final index = match.group(2)!;
  return ['LRV_${stamp}_11_$index.lrv', 'LRV_${stamp}_01_$index.lrv'];
}

/// Where the LRV copies of the Insta360 video at [url] would be, next to it: [url] a path or a file:// URI of this
/// computer, or a media bridge URL (a share, through the loopback address). None for a URL of the server, whose paths
/// carry no file names, and for any other file.
List<String> lowResolutionCandidates(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    if (!_loopback(uri.host) || uri.pathSegments.isEmpty) {
      return const [];
    }
    final segments = uri.pathSegments;
    return [
      for (final name in lowResolutionNamesOf(segments.last))
        uri.replace(pathSegments: [...segments.take(segments.length - 1), name]).toString(),
    ];
  }
  if (uri != null && uri.scheme == 'file') {
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      return const [];
    }
    return [
      for (final name in lowResolutionNamesOf(segments.last))
        uri.replace(pathSegments: [...segments.take(segments.length - 1), name]).toString(),
    ];
  }
  final slash = url.lastIndexOf(RegExp(r'[/\\]'));
  final folder = slash < 0 ? '' : url.substring(0, slash + 1);
  return [for (final name in lowResolutionNamesOf(url.substring(slash + 1))) '$folder$name'];
}

bool _loopback(String host) => host == '127.0.0.1' || host == 'localhost' || host == '::1' || host == '[::1]';

/// Whether [url] can be read: a file of this computer that exists, or a bridge URL that answers a HEAD request
Future<bool> rawUrlReadable(String url, {Duration timeout = const Duration(seconds: 3)}) async {
  final uri = Uri.tryParse(url);
  try {
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      if (!_loopback(uri.host)) {
        // The server's URLs are not asked: the bridge carries their session, a direct request would not
        return true;
      }
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final request = await client.headUrl(uri).timeout(timeout);
        final response = await request.close().timeout(timeout);
        await response.drain<void>();
        return response.statusCode >= 200 && response.statusCode < 300;
      } finally {
        client.close(force: true);
      }
    }
    final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : url;
    // ignore: avoid_slow_async_io, the file may be on a share mounted by Windows, slow to answer
    return await File(path).exists();
  } catch (_) {
    return false;
  }
}

/// The LRV copy next to the Insta360 video at [url], null when none is found; [readable] answers whether a candidate
/// exists (see [rawUrlReadable])
Future<String?> findLowResolutionCopy(String url, {Future<bool> Function(String url) readable = rawUrlReadable}) async {
  for (final candidate in lowResolutionCandidates(url)) {
    if (await readable(candidate)) {
      return candidate;
    }
  }
  return null;
}
