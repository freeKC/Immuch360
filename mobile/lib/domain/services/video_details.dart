// What the technical details of a video tell beyond its codec and its frame size: its bit rate, the profile its codecs
// string names, and its picture (bit depth, HDR transfer, colour primaries), from what the probe of its file found
// (see SphericalProbe). What a user asks when a 360° video stutters or looks flat: an 8K 10 bit HLG file at 200 Mbit/s
// is not the same load as an 8 bit export at 60.

import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:intl/intl.dart';

const _separator = '  •  ';

/// Where a bit rate comes from, from the most precise to the least: the sample sizes of the video tracks (stsz), the
/// average the file declares (btrt), the media data of the whole file (audio included), or the file size over the
/// duration (an estimate, headers included)
enum VideoBitRateSource { videoTracks, declared, mediaData, fileSize }

typedef VideoBitRate = ({int bitsPerSecond, VideoBitRateSource source});

/// The bit rate the details show: of the video tracks (stsz), else the one the file declares (btrt), else of the
/// media data (mdat, whole file), else the file size over the duration ([fileSize] bytes, [durationMs]); null when
/// nothing tells it
VideoBitRate? videoBitRateOf({SphericalProbe? probe, int? fileSize, int? durationMs}) {
  final candidates = [
    (probe?.videoBitRate, VideoBitRateSource.videoTracks),
    (probe?.declaredBitRate, VideoBitRateSource.declared),
    (probe?.mediaBitRate, VideoBitRateSource.mediaData),
  ];
  for (final (rate, source) in candidates) {
    if (rate != null && rate > 0) {
      return (bitsPerSecond: rate, source: source);
    }
  }
  if (fileSize != null && fileSize > 0 && durationMs != null && durationMs > 0) {
    return (bitsPerSecond: (fileSize * 8000 / durationMs).round(), source: VideoBitRateSource.fileSize);
  }
  return null;
}

/// "210 Mbit/s", "4.5 Mbit/s", "850 kbit/s", with the decimal separator of [locale]
String formatBitRate(int bitsPerSecond, Translations t, {required String locale}) {
  if (bitsPerSecond < 1000000) {
    return t.technical_details_bit_rate_kbps(value: _decimalFormat(locale).format((bitsPerSecond / 1000).round()));
  }
  final mbps = bitsPerSecond / 1000000;
  // One decimal below 10 Mbit/s, where it tells a phone recording from another; none above, where it is noise
  final format = _decimalFormat(locale)..maximumFractionDigits = mbps < 10 ? 1 : 0;
  return t.technical_details_bit_rate_mbps(value: format.format(mbps));
}

// The number format of [locale], the English one for a language intl has no number symbols for
NumberFormat _decimalFormat(String locale) {
  try {
    return NumberFormat.decimalPattern(locale);
  } on ArgumentError {
    return NumberFormat.decimalPattern('en');
  }
}

/// The profile an RFC 6381 codecs string names, as the decoders page names it ("Main 10" for "hvc1.2.4.L153", "High"
/// for "avc1.640033", "Profile 8" for "dvh1.08.06"); null when unknown
String? videoProfileName(String? codecs) {
  if (codecs == null) {
    return null;
  }
  final parts = codecs.trim().split('.');
  if (parts.length < 2 || parts[1].isEmpty) {
    return null;
  }
  final profile = parts[1];
  switch (parts.first.toLowerCase()) {
    case 'hvc1' || 'hev1':
      // The profile space comes as a letter before the profile number: "A1" is profile 1 too
      return switch (profile.replaceFirst(RegExp('^[ABCabc]'), '')) {
        '1' => 'Main',
        '2' => 'Main 10',
        '3' => 'Main Still',
        '4' => 'Range extensions',
        _ => null,
      };
    case 'avc1' || 'avc3':
      if (profile.length < 4) {
        return null;
      }
      final constraints = int.tryParse(profile.substring(2, 4), radix: 16) ?? 0;
      return switch (profile.substring(0, 2).toUpperCase()) {
        // constraint_set1_flag: the stream also follows the Main profile
        '42' => (constraints & 0x40) != 0 ? 'Constrained Baseline' : 'Baseline',
        '4D' => 'Main',
        '58' => 'Extended',
        '64' => 'High',
        '6E' => 'High 10',
        '7A' => 'High 4:2:2',
        'F4' => 'High 4:4:4',
        _ => null,
      };
    case 'av01':
      return switch (profile) {
        '0' => 'Main',
        '1' => 'High',
        '2' => 'Professional',
        _ => null,
      };
    case 'dvh1' || 'dvhe' || 'dav1':
      final number = int.tryParse(profile);
      return number == null ? null : 'Profile $number';
    default:
      return null;
  }
}

/// The picture of the video [probe] describes, for the details: its bit depth, Dolby Vision, its transfer (HDR HLG,
/// HDR10 PQ or SDR) and its colour primaries ("10 bit  •  HDR, HLG  •  BT.2020"); null when the file tells none
String? videoPictureSummary(SphericalProbe? probe, Translations t) {
  if (probe == null) {
    return null;
  }
  final bitDepth = probe.bitDepth;
  final parts = [
    if (bitDepth != null) t.technical_details_bit_depth(bits: '$bitDepth'),
    if (probe.dolbyVision) t.technical_details_dolby_vision,
    ...switch (probe.dynamicRange) {
      VideoDynamicRange.hlg => [t.technical_details_hdr_hlg],
      VideoDynamicRange.pq => [t.technical_details_hdr_pq],
      VideoDynamicRange.sdr => [t.technical_details_sdr],
      null => const <String>[],
    },
    // The names of the standards, not translated
    ...switch (probe.colourPrimaries) {
      1 => const ['BT.709'],
      5 || 6 => const ['BT.601'],
      9 => const ['BT.2020'],
      11 => const ['DCI-P3'],
      12 => const ['Display P3'],
      _ => const <String>[],
    },
  ];
  return parts.isEmpty ? null : parts.join(_separator);
}
