// VideoDecoderApi on the computers (design 2.7): whether the computer decodes a video, asked before the original of a
// server video plays (chooseVideoSource) and before two streams play at once (warnOfTwoRawStreams), and its decoders
// for the decoders page of the troubleshooting settings, through the same pigeon contract as the phones.
//
// - Windows: the Direct3D 11 decoder profiles of the GPU in use (DesktopGpuDecoders, through the immuch_desktop_video
//   plugin). A profile FFmpeg decodes the codec, depth and chroma with, taking the coded size, means hardware
//   decoding; anything else goes to FFmpeg's software decoders, which mpv falls back to by itself (hwdec auto-safe).
//   On the GPUs measured so far that sends H.264 above 4096 to the processor: no Direct3D, DXVA2 or NVDEC decoder of
//   an RTX 4060 or an Intel UHD takes it.
// - Linux and macOS, until their probes exist (plan 20, phase 4): the static rule, software up to 8192 x 8192.
// - Everywhere, the measured correction (decoder_measure.dart) has the last word: what a playback of the same kind of
//   video did on this computer, or what the same GPU kind and decoding path did while the app was built. Two streams
//   at once (raw two lens files) are held to the pixel rate measured stacked in one player.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopVideoDecoderApi');

/// What a video asks of a decoder: its codec as a MIME type, the bit depth and chroma of its frames, and the name of
/// its profile as the decoders page writes it (null for the codecs without profiles worth naming)
typedef DesktopCodecNeed = ({String mime, int bitDepth, String chroma, String? profile});

// MIME type of each sample entry four character code and of each codec name of ffprobe (what the Immich server
// reports), as the phones map them; Dolby Vision as the codec of its base layer, which is what FFmpeg decodes
const _mimeByCodec = {
  'avc1': VideoMime.avc,
  'avc3': VideoMime.avc,
  'h264': VideoMime.avc,
  'hvc1': VideoMime.hevc,
  'hev1': VideoMime.hevc,
  'hevc': VideoMime.hevc,
  'h265': VideoMime.hevc,
  'av01': VideoMime.av1,
  'av1': VideoMime.av1,
  'vp09': VideoMime.vp9,
  'vp9': VideoMime.vp9,
  'vp08': VideoMime.vp8,
  'vp8': VideoMime.vp8,
  'mp4v': VideoMime.mpeg4,
  'mpeg4': VideoMime.mpeg4,
  'mpeg2video': VideoMime.mpeg2,
  'vc1': VideoMime.vc1,
  'dvh1': VideoMime.hevc,
  'dvhe': VideoMime.hevc,
  'dva1': VideoMime.avc,
  'dvav': VideoMime.avc,
  'dav1': VideoMime.av1,
};

const _dolbyVision = {'dvh1', 'dvhe', 'dva1', 'dvav', 'dav1', 'video/dolby-vision'};

/// The MIME type of [codec]: a MIME type as it is, or a four character code or codec name, alone or leading an RFC
/// 6381 string ("hvc1.2.4.L153.B0" gives "video/hevc"); null for a blank or unknown one. The raw two lens switch
/// asks it about the tracks of a rawProjection JSON (raw_two_stream_switch.dart).
String? desktopMimeFor(String codec) {
  final value = codec.trim().toLowerCase();
  if (value.isEmpty) {
    return null;
  }
  if (value == 'video/dolby-vision') {
    return VideoMime.hevc;
  }
  if (value.contains('/')) {
    return value;
  }
  return _mimeByCodec[value.split('.').first];
}

/// What a video of [codec] (with its RFC 6381 [codecs] when known, [bitDepth] bits per luma sample and the H.273
/// [transfer], each 0 when unknown) asks of a decoder; null for an unknown codec
@visibleForTesting
DesktopCodecNeed? desktopCodecNeed(String codec, String? codecs, int bitDepth, int transfer) {
  final mime = desktopMimeFor(codec) ?? (codecs == null ? null : desktopMimeFor(codecs));
  if (mime == null) {
    return null;
  }
  final string = (codecs ?? codec).trim().toLowerCase();
  final fields = string.split('.');
  final entry = fields.first;
  // HDR (PQ, HLG) and Dolby Vision are 10 bit at least, whatever the file forgot to say
  final hdr = transfer == 16 || transfer == 18 || _dolbyVision.contains(entry) || _dolbyVision.contains(codec.trim());
  var depth = bitDepth > 0 ? bitDepth : (hdr ? 10 : 8);
  // A decimal field of the codecs string; HEVC prefixes its profile with the profile space (A to C), never used
  int? field(int index) => fields.length > index ? int.tryParse(fields[index].replaceAll(RegExp('^[a-c]'), '')) : null;
  switch (mime) {
    case VideoMime.avc:
      if (entry == 'avc1' || entry == 'avc3') {
        final idc = fields.length > 1 && fields[1].length >= 2
            ? int.tryParse(fields[1].substring(0, 2), radix: 16)
            : null;
        switch (idc) {
          case 110:
            return (mime: mime, bitDepth: math.max(depth, 10), chroma: '4:2:0', profile: 'High 10');
          case 122:
            return (mime: mime, bitDepth: depth, chroma: '4:2:2', profile: 'High 4:2:2');
          case 244:
            return (mime: mime, bitDepth: depth, chroma: '4:4:4', profile: 'High 4:4:4');
          case 66:
            return (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: 'Baseline');
          case 77:
            return (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: 'Main');
        }
      }
      return (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: depth > 8 ? 'High 10' : 'High');
    case VideoMime.hevc:
      if (entry == 'hvc1' || entry == 'hev1') {
        switch (field(1)) {
          case 1:
            depth = bitDepth > 0 ? bitDepth : 8;
          case 2:
            depth = math.max(depth, 10);
          case 4:
            // Range extensions: 4:2:2 and 4:4:4 of the professional cameras, which no decoding mode of FFmpeg takes
            return (mime: mime, bitDepth: depth, chroma: '4:2:2', profile: 'Range extensions');
        }
      }
      final name = switch (depth) {
        <= 8 => 'Main',
        <= 10 => 'Main 10',
        _ => 'Main 12',
      };
      return (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: name);
    case VideoMime.vp9:
      final profile = entry == 'vp09' ? field(1) : null;
      final declared = entry == 'vp09' ? field(3) : null;
      if (declared != null && declared > 0) {
        depth = declared;
      }
      final chroma = profile == 1 || profile == 3 ? '4:4:4' : '4:2:0';
      final number = profile ?? (depth > 8 ? 2 : 0);
      return (mime: mime, bitDepth: depth, chroma: chroma, profile: 'Profile $number');
    case VideoMime.av1:
      final profile = entry == 'av01' ? field(1) : null;
      final declared = entry == 'av01' ? field(3) : null;
      if (declared != null && declared > 0) {
        depth = declared;
      }
      return switch (profile) {
        1 => (mime: mime, bitDepth: depth, chroma: '4:4:4', profile: 'High'),
        2 => (mime: mime, bitDepth: depth, chroma: '4:2:2', profile: 'Professional'),
        _ => (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: 'Main'),
      };
    default:
      return (mime: mime, bitDepth: depth, chroma: '4:2:0', profile: null);
  }
}

/// The DXGI output format FFmpeg asks a decoder for at [bitDepth] bits
String _outputFormat(int bitDepth) => switch (bitDepth) {
  <= 8 => 'NV12',
  <= 10 => 'P010',
  _ => 'P016',
};

/// The hardware profile that decodes a video, with the largest frame it takes
typedef _HardwareFit = ({D3D11DecoderProfile profile, D3D11ProfileInfo info});

class DesktopVideoDecoderApi implements VideoDecoderApi {
  DesktopVideoDecoderApi({DecoderMeasureStore? measures, DateTime Function()? now})
    : _measures = measures ?? DecoderMeasureStore.shared,
      _now = now ?? DateTime.now;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final DecoderMeasureStore _measures;
  final DateTime Function() _now;

  /// The largest frame FFmpeg's software decoders are taken to decode (the static rule)
  static const maxWidth = 8192;
  static const maxHeight = 8192;

  /// Pixels a second that two streams at once may reach: an Insta360 X3 pair (two 2880 x 2880 H.264 files) stacked
  /// in one player kept 30 fps on an RTX 4060 Laptop (decoded and copied back) and on an Intel UHD (decoded in
  /// software), while an X4 file (two 3840 x 3840 HEVC tracks) stacked at 7 to 9 fps even on the RTX (phase 2b, spike
  /// 5). Until the raw two lens player measures pairs itself, more than this "may not be smooth".
  static const twoStreamPixelRate = 2 * 2880 * 2880 * 30.0;

  /// The codecs FFmpeg decodes in software that the decoders page lists
  static const softwareCodecs = [VideoMime.avc, VideoMime.hevc, VideoMime.av1, VideoMime.vp9];

  /// The order of the codecs on the decoders page
  static const _codecOrder = [
    VideoMime.avc,
    VideoMime.hevc,
    VideoMime.av1,
    VideoMime.vp9,
    VideoMime.vp8,
    VideoMime.mpeg2,
    VideoMime.vc1,
    VideoMime.mpeg4,
  ];

  @override
  Future<DecodeVerdict> canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  }) async {
    final need = desktopCodecNeed(codec, codecs, bitDepth, transferCharacteristics);
    if (need == null) {
      return DecodeVerdict(
        supported: true,
        hardware: false,
        maxWidth: 0,
        maxHeight: 0,
        reason: "unknown codec '$codec'",
      );
    }
    final decoders = await DesktopGpuDecoders.decoders();
    final adapter = decoders?.adapter;
    final usable = decoders != null && decoders.error == null;
    final fit = usable ? await _hardwareFit(decoders, need, width, height) : null;
    final listed = usable && _listsProfile(decoders, need);
    final fitsSoftware = width <= maxWidth && height <= maxHeight;
    var supported = fit != null || fitsSoftware;
    var hardware = fit != null;
    var maxSize = (width: maxWidth, height: maxHeight);
    final size = '${width}x$height';
    final label = [videoCodecLabel(need.mime), ?need.profile].join(' ');
    String reason;
    if (fit != null) {
      final largest = fit.profile.largest;
      if (largest != null) {
        maxSize = (width: largest.width, height: largest.height);
      }
      reason = 'hardware: ${adapter?.name} decodes $label at $size (Direct3D 11 ${fit.info.name})';
    } else if (!usable) {
      reason = fitsSoftware
          ? 'desktop static answer: software decoding up to ${maxWidth}x$maxHeight'
          : 'desktop static answer: larger than ${maxWidth}x$maxHeight';
    } else {
      final why = listed ? 'does not take $label at $size' : 'has no $label decoder';
      reason = fitsSoftware
          ? 'software: ${adapter?.name ?? 'the GPU'} $why'
          : 'larger than ${maxWidth}x$maxHeight, and ${adapter?.name ?? 'the GPU'} $why';
    }
    if (instances > 1 && supported) {
      final rate = instances * width * height * math.max(frameRate, 30);
      if (rate > twoStreamPixelRate) {
        supported = false;
        reason =
            '$instances streams of $size at ${frameRate > 0 ? frameRate : 30} fps: '
            '${(rate / 1e6).round()} Mpx/s, above the ${(twoStreamPixelRate / 1e6).round()} Mpx/s measured smooth '
            'for two streams in one player';
      }
    }
    final correction = await _measures.correction(
      gpu: adapter?.key ?? MeasuredGpu.unknown,
      integrated: adapter?.integrated,
      codec: need.mime,
      width: width,
      height: height,
      frameRate: frameRate,
      hardware: hardware,
      instances: instances,
      buildMeasures: usable,
      now: _now(),
    );
    if (correction != null) {
      final measure = correction.measure;
      supported = measure.smooth;
      hardware = measure.hardware;
      final where = correction.own
          ? 'measured on this computer'
          : 'measured while the app was built (${measure.source})';
      reason = '$where: ${measure.describe()}';
    }
    final verdict = DecodeVerdict(
      supported: supported,
      hardware: hardware,
      maxWidth: maxSize.width,
      maxHeight: maxSize.height,
      reason: reason,
      profile: need.profile,
      missingProfile: !supported && usable && !listed ? need.profile : null,
    );
    _log.fine('$codec ${codecs ?? ''} $size ${frameRate}fps ${bitDepth}bit x$instances: $reason');
    return verdict;
  }

  /// Whether the GPU lists a profile FFmpeg would decode [need] with, whatever the size
  static bool _listsProfile(D3D11DecoderProbe decoders, DesktopCodecNeed need) {
    final format = _outputFormat(need.bitDepth);
    return ffmpegProfilesFor(
      need.mime,
      bitDepth: need.bitDepth,
      chroma: need.chroma,
    ).any((guid) => decoders.profile(guid)?.formats.contains(format) ?? false);
  }

  /// The profile of the GPU that decodes [need] at [width] x [height], in FFmpeg's order, null when none does
  static Future<_HardwareFit?> _hardwareFit(
    D3D11DecoderProbe decoders,
    DesktopCodecNeed need,
    int width,
    int height,
  ) async {
    final format = _outputFormat(need.bitDepth);
    final coded = codedSize(need.mime, width, height);
    for (final guid in ffmpegProfilesFor(need.mime, bitDepth: need.bitDepth, chroma: need.chroma)) {
      final profile = decoders.profile(guid);
      final info = d3d11ProfileInfo(guid);
      if (profile == null || info == null || !profile.formats.contains(format)) {
        continue;
      }
      if (width <= 0 || height <= 0 || await DesktopGpuDecoders.accepts(guid, coded.width, coded.height) == true) {
        return (profile: profile, info: info);
      }
    }
    return null;
  }

  @override
  Future<List<DecoderInfo>> listDecoders() async {
    final decoders = await DesktopGpuDecoders.decoders();
    final adapter = decoders?.adapter;
    final rows = <DecoderInfo>[];
    if (decoders != null && adapter != null) {
      final gpu = '${adapter.name.trim().isEmpty ? 'GPU' : adapter.name.trim()} (Direct3D 11)';
      for (final profile in decoders.profiles) {
        final info = d3d11ProfileInfo(profile.guid);
        final largest = profile.largest;
        // A profile the driver lists without taking any frame size in its first output format (the stereo modes of
        // H.264 on both GPUs measured): nothing FFmpeg could use
        if (info == null || largest == null) {
          continue;
        }
        rows.add(
          DecoderInfo(
            name: gpu,
            codec: info.codec,
            hardware: true,
            maxWidth: largest.width,
            maxHeight: largest.height,
            maxFrameRate: profile.maxFrameRate ?? 0,
            profiles: ['${info.name} (${profile.formats.join(', ')})'],
          ),
        );
      }
      int order(DecoderInfo row) {
        final index = _codecOrder.indexOf(row.codec);
        return index < 0 ? _codecOrder.length : index;
      }

      mergeSort(rows, compare: (a, b) => order(a) - order(b));
    }
    for (final codec in softwareCodecs) {
      rows.add(
        DecoderInfo(
          name: 'FFmpeg (software)',
          codec: codec,
          hardware: false,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          maxFrameRate: 0,
        ),
      );
    }
    for (final measure in await _measures.ownOn(adapter?.key ?? MeasuredGpu.unknown, now: _now())) {
      rows.add(
        DecoderInfo(
          name:
              'Measured in playback: ${measure.instances > 1 ? '${measure.instances} streams, ' : ''}${measure.hwdec}, '
              '${measure.dropped} of ${measure.frames} frames dropped',
          codec: measure.codec,
          hardware: measure.hardware,
          maxWidth: measure.width,
          maxHeight: measure.height,
          maxFrameRate: (measure.shownRate * 100).round() / 100,
        ),
      );
    }
    return rows;
  }
}
