// Google Cast for a Plex film ("Play on..." through Cast, experimental): what the phone tells the default media
// receiver of a Chromecast, a Google TV, an Android TV with Cast built in or a Nest Hub, and what it knows beforehand
// of whether that device decodes the film.
//
// The receiver reads the film from the phone's relay (cast_relay.dart), never from the Plex server: the LOAD message
// carries the relay's one time address and the film's title, year and poster (through the relay too), never a token
// nor the server's address.
//
// The format check is a static table of what Google documents for its devices ("Supported media for Google Cast")
// and of the models a Cast device announces in its TXT record (md): the same idea as the player choice of the libmpv
// lot (the Plex metadata read before playback), with its own table, since the receiver is not this device.

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// The default media receiver of every Cast device (Styled Media Receiver), which needs no registration
const castDefaultReceiverAppId = 'CC1AD845';

const castNamespaceConnection = 'urn:x-cast:com.google.cast.tp.connection';
const castNamespaceHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
const castNamespaceReceiver = 'urn:x-cast:com.google.cast.receiver';
const castNamespaceMedia = 'urn:x-cast:com.google.cast.media';

/// The platform's end of a Cast channel
const castReceiverId = 'receiver-0';

/// What a LOAD asks the receiver to play: everything is an address of the relay or a text of the film
class CastFilm {
  const CastFilm({
    required this.contentUrl,
    required this.contentType,
    required this.title,
    this.year,
    this.posterUrl,
    this.durationMs,
    this.startMs = 0,
  });

  final Uri contentUrl;
  final String contentType;
  final String title;
  final int? year;
  final Uri? posterUrl;
  final int? durationMs;
  final int startMs;
}

/// The LOAD message of the media namespace for [film] (MovieMediaMetadata, metadataType 1), autoplay from its start
/// position. Built from the relay's addresses and the film's texts only: there is no parameter a token could come by.
Map<String, Object?> castLoadMessage(CastFilm film) {
  final year = film.year;
  final poster = film.posterUrl;
  final duration = film.durationMs;
  return {
    'type': 'LOAD',
    'autoplay': true,
    'currentTime': film.startMs <= 0 ? 0 : film.startMs / 1000,
    'media': {
      'contentId': film.contentUrl.toString(),
      'contentUrl': film.contentUrl.toString(),
      'streamType': 'BUFFERED',
      'contentType': film.contentType,
      if (duration != null && duration > 0) 'duration': duration / 1000,
      'metadata': {
        'metadataType': 1,
        'title': film.title,
        if (year != null) ...{'subtitle': '$year', 'releaseDate': '$year'},
        if (poster != null)
          'images': [
            {'url': poster.toString()},
          ],
      },
    },
  };
}

/// The content type a LOAD gives for a file of [container] (Plex's word: "mp4", "mkv"...), else of [fileName]'s
/// extension. The default receiver plays a progressive file through its media element, which reads the container
/// itself; "video/mp4" is the type it takes as such a file in every version, so Matroska goes with it too (an
/// assumption the manual test of the lot checks).
String castContentTypeOf({String? container, String? fileName}) {
  var kind = container?.toLowerCase().trim();
  if (kind == null || kind.isEmpty) {
    final name = fileName ?? '';
    final dot = name.lastIndexOf('.');
    kind = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
  return switch (kind) {
    'webm' => 'video/webm',
    'mp3' => 'audio/mpeg',
    _ => 'video/mp4',
  };
}

/// Whether a device decodes something
enum CastSupport { yes, maybe, no }

/// What a Cast device decodes beyond H.264 up to 1080p, VP8, AAC, MP3, Opus, Vorbis and FLAC (every Cast video device)
class CastDeviceProfile {
  const CastDeviceProfile({required this.hevc, required this.vp9, required this.av1, required this.uhd});

  final CastSupport hevc;
  final CastSupport vp9;
  final CastSupport av1;

  /// Pictures larger than 1080p
  final CastSupport uhd;

  /// A model the table does not know (most Android TVs with Cast built in): only the common set is sure
  static const unknown = CastDeviceProfile(
    hevc: CastSupport.maybe,
    vp9: CastSupport.maybe,
    av1: CastSupport.maybe,
    uhd: CastSupport.maybe,
  );
}

/// The profile of a device by the model it announces (TXT md). "Chromecast" alone is the first three generations and,
/// on some firmware, the Chromecast with Google TV: unsure beyond the common set.
CastDeviceProfile castProfileOf(String? model) {
  final md = (model ?? '').toLowerCase().trim();
  if (md.contains('google tv streamer')) {
    return const CastDeviceProfile(
      hevc: CastSupport.yes,
      vp9: CastSupport.yes,
      av1: CastSupport.yes,
      uhd: CastSupport.yes,
    );
  }
  if (md.contains('chromecast ultra')) {
    return const CastDeviceProfile(
      hevc: CastSupport.yes,
      vp9: CastSupport.yes,
      av1: CastSupport.no,
      uhd: CastSupport.yes,
    );
  }
  if (md == 'chromecast hd') {
    return const CastDeviceProfile(
      hevc: CastSupport.yes,
      vp9: CastSupport.yes,
      av1: CastSupport.yes,
      uhd: CastSupport.no,
    );
  }
  if (md.contains('nest hub') || md.contains('home hub')) {
    return const CastDeviceProfile(
      hevc: CastSupport.no,
      vp9: CastSupport.maybe,
      av1: CastSupport.no,
      uhd: CastSupport.no,
    );
  }
  return CastDeviceProfile.unknown;
}

/// What of a film a device may not decode
enum CastIssueKind { container, video, audio, size }

class CastIssue {
  const CastIssue(this.kind, this.support, this.name);

  final CastIssueKind kind;
  final CastSupport support;

  /// The format's usual name ("AVI", "DTS", "HEVC"), or the picture's size ("4K")
  final String name;

  @override
  bool operator ==(Object other) =>
      other is CastIssue && other.kind == kind && other.support == support && other.name == name;

  @override
  int get hashCode => Object.hash(kind, support, name);

  @override
  String toString() => 'CastIssue(${kind.name}, ${support.name}, $name)';
}

/// What the Plex metadata tells of the version of the film that would be cast: its container, its video codec, the
/// codec of the sound the receiver plays (the file's default track: a progressive file plays that one) and its size
class CastFilmFormat {
  const CastFilmFormat({this.container, this.videoCodec, this.audioCodec, this.width, this.height});

  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final int? width;
  final int? height;
}

/// The verdict before casting: plays, may not play (with why), cannot play (with why)
class CastFormatCheck {
  const CastFormatCheck(this.issues);

  final List<CastIssue> issues;

  CastSupport get support {
    if (issues.any((issue) => issue.support == CastSupport.no)) {
      return CastSupport.no;
    }
    return issues.isEmpty ? CastSupport.yes : CastSupport.maybe;
  }

  /// The issues of the verdict's level: what a "cannot play" line names
  List<CastIssue> get reasons => [
    for (final issue in issues)
      if (issue.support == support) issue,
  ];
}

const _playableContainers = {'mp4', 'm4v', 'mov', 'webm', 'mp3'};
const _maybeContainers = {'mkv', 'matroska'};
const _containerNames = {
  'avi': 'AVI',
  'wmv': 'WMV',
  'asf': 'WMV',
  'flv': 'FLV',
  'mpegts': 'MPEG-TS',
  'ts': 'MPEG-TS',
  'm2ts': 'M2TS',
  'mpeg': 'MPEG-PS',
  'mpg': 'MPEG-PS',
  'vob': 'VOB',
  'ogm': 'OGM',
  'rm': 'RealMedia',
  'rmvb': 'RealMedia',
  '3gp': '3GP',
  'mkv': 'Matroska',
  'matroska': 'Matroska',
};
const _commonAudio = {'aac', 'mp3', 'opus', 'vorbis', 'flac', 'pcm', 'lpcm'};
const _dolbyAudio = {'ac3', 'eac3'};
const _codecNames = {
  'hevc': 'HEVC',
  'h265': 'HEVC',
  'av1': 'AV1',
  'vp9': 'VP9',
  'mpeg4': 'MPEG-4 Part 2',
  'msmpeg4': 'DivX 3',
  'msmpeg4v2': 'DivX 3',
  'msmpeg4v3': 'DivX 3',
  'wmv1': 'WMV',
  'wmv2': 'WMV',
  'wmv3': 'WMV',
  'vc1': 'VC-1',
  'mpeg2video': 'MPEG-2',
  'mpeg1video': 'MPEG-1',
  'h263': 'H.263',
  'theora': 'Theora',
  'ac3': 'Dolby Digital',
  'eac3': 'Dolby Digital Plus',
  'dts': 'DTS',
  'dca': 'DTS',
  'truehd': 'Dolby TrueHD',
  'mlp': 'Dolby TrueHD',
  'wmav1': 'WMA',
  'wmav2': 'WMA',
  'wmapro': 'WMA',
  'mp2': 'MPEG audio layer II',
  'alac': 'ALAC',
};

String _nameOf(String codec) => _codecNames[codec] ?? codec.toUpperCase();

/// Whether [profile] decodes [format], from Google's list and the table above. Unknown fields add nothing: the check
/// warns about what it knows, it never blocks on what it does not.
CastFormatCheck checkCastFormat(CastFilmFormat format, CastDeviceProfile profile) {
  final issues = <CastIssue>[];
  final container = format.container?.toLowerCase().trim();
  if (container != null && container.isNotEmpty && !_playableContainers.contains(container)) {
    issues.add(
      CastIssue(
        CastIssueKind.container,
        _maybeContainers.contains(container) ? CastSupport.maybe : CastSupport.no,
        _containerNames[container] ?? container.toUpperCase(),
      ),
    );
  }
  final video = format.videoCodec?.toLowerCase().trim();
  if (video != null && video.isNotEmpty) {
    final support = switch (video) {
      'h264' || 'avc' || 'avc1' || 'vp8' => CastSupport.yes,
      'hevc' || 'h265' => profile.hevc,
      'vp9' => profile.vp9,
      'av1' => profile.av1,
      _ => CastSupport.no,
    };
    if (support != CastSupport.yes) {
      issues.add(CastIssue(CastIssueKind.video, support, _nameOf(video)));
    }
  }
  final audio = format.audioCodec?.toLowerCase().trim();
  if (audio != null && audio.isNotEmpty && !_commonAudio.contains(audio)) {
    // Dolby Digital goes through to a TV or an amplifier that decodes it, on the devices that pass it through
    issues.add(
      CastIssue(CastIssueKind.audio, _dolbyAudio.contains(audio) ? CastSupport.maybe : CastSupport.no, _nameOf(audio)),
    );
  }
  final width = format.width ?? 0;
  final height = format.height ?? 0;
  if ((width > 1920 || height > 1088) && profile.uhd != CastSupport.yes) {
    issues.add(CastIssue(CastIssueKind.size, profile.uhd, '4K'));
  }
  return CastFormatCheck(issues);
}

/// The phone's address the receiver should read the relay at: among [local] (this phone's IPv4 addresses), the private
/// one that shares the most leading bits with [device]'s (the same subnet when there is one); null when the phone has
/// no private IPv4 address, or [device] is no private IPv4 address.
String? castRelayAddressFor(List<String> local, String device) {
  final target = _ipv4Bits(device);
  if (target == null || !isPrivatePairingIPv4(device)) {
    return null;
  }
  String? best;
  var bestBits = -1;
  for (final address in local) {
    final bits = _ipv4Bits(address);
    if (bits == null || !isPrivatePairingIPv4(address) || address == device) {
      continue;
    }
    final common = _commonLeadingBits(bits, target);
    if (common > bestBits) {
      best = address;
      bestBits = common;
    }
  }
  return best;
}

int? _ipv4Bits(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  var value = 0;
  for (final part in parts) {
    final byte = int.tryParse(part);
    if (byte == null || byte < 0 || byte > 255) {
      return null;
    }
    value = (value << 8) | byte;
  }
  return value;
}

int _commonLeadingBits(int a, int b) {
  var bits = 0;
  for (var bit = 31; bit >= 0; bit--) {
    if ((a >> bit) & 1 != (b >> bit) & 1) {
      break;
    }
    bits++;
  }
  return bits;
}

/// A Cast device found on the network (an mDNS answer of _googlecast._tcp)
class CastTarget {
  const CastTarget({required this.id, required this.name, required this.host, required this.port, this.model});

  /// Its TXT id, else its service name: what one device keeps across answers
  final String id;

  /// What its owner named it (TXT fn), else its model, else the service name
  final String name;

  /// Its IPv4 address
  final String host;
  final int port;

  /// What it is (TXT md): "Chromecast", "Google Nest Hub", "SHIELD Android TV"
  final String? model;

  @override
  bool operator ==(Object other) =>
      other is CastTarget &&
      other.id == id &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.model == model;

  @override
  int get hashCode => Object.hash(id, name, host, port, model);
}

/// The Cast device of an mDNS answer: null for one without a screen (TXT ca without its display bit: a speaker or a
/// speaker group), and for an address that is no private IPv4 literal ([host] is the resolved one)
CastTarget? castTargetOf({
  required String serviceName,
  required String host,
  required int port,
  required Map<String, String> attributes,
}) {
  final capabilities = int.tryParse(attributes['ca'] ?? '');
  if (capabilities != null && capabilities & 0x01 == 0) {
    return null;
  }
  if (!isPrivatePairingIPv4(host) || port <= 0 || port > 65535) {
    return null;
  }
  final model = attributes['md']?.trim();
  final friendly = attributes['fn']?.trim();
  final id = attributes['id']?.trim();
  return CastTarget(
    id: id == null || id.isEmpty ? serviceName : id,
    name: friendly != null && friendly.isNotEmpty
        ? friendly
        : (model != null && model.isNotEmpty ? model : serviceName),
    host: host,
    port: port,
    model: model == null || model.isEmpty ? null : model,
  );
}

/// The Cast group of the sheet: the devices by name, one row per device, without those at the address of a linked
/// screen announced nearby ([screenHosts]): that box runs Immuch360, whose own row plays every format the app plays
/// and keeps the film on the sealed link
List<CastTarget> castRowsOf(Iterable<CastTarget> found, Set<String> screenHosts) {
  final byId = <String, CastTarget>{};
  for (final target in found) {
    if (!screenHosts.contains(target.host)) {
      byId[target.id] = target;
    }
  }
  return byId.values.toList()..sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
}
