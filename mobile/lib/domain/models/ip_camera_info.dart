// What the app keeps of a camera of another brand than Tapo (see NetworkSource.ipCamera): how it was added (ONVIF or
// a typed RTSP address), where its ONVIF device service answers, what it told of itself and of its two streams.
// Nothing secret: the password and the stream addresses (whose path or query may hold a token) live in the secure
// storage (camera_address.dart, IpCameraStreams).

/// How the camera was added
enum IpCameraKind {
  /// Found by WS-Discovery or by its address, read through ONVIF
  onvif,

  /// An RTSP or RTSPS address pasted by the user (UniFi Protect, go2rtc, Frigate, a camera without ONVIF)
  rtsp,
}

/// What a stream of the camera is, as ONVIF announced it (a hint) or the test of the stream read it in the SDP
class IpCameraStreamInfo {
  const IpCameraStreamInfo({this.profileToken, this.codec, this.width, this.height, this.audio});

  /// The ONVIF profile, null for a typed address
  final String? profileToken;

  /// "H264", "H265", "JPEG", null when unknown
  final String? codec;
  final int? width;
  final int? height;

  /// "PCMA", "PCMU", "MPEG4-GENERIC", "G711", "AAC", null without sound or when unknown
  final String? audio;

  Map<String, Object?> toJson() => {
    'profileToken': ?profileToken,
    'codec': ?codec,
    'width': ?width,
    'height': ?height,
    'audio': ?audio,
  };

  static IpCameraStreamInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    String? text(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    int? number(String key) => json[key] is int ? json[key] as int : null;
    return IpCameraStreamInfo(
      profileToken: text('profileToken'),
      codec: text('codec'),
      width: number('width'),
      height: number('height'),
      audio: text('audio'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IpCameraStreamInfo &&
      other.profileToken == profileToken &&
      other.codec == codec &&
      other.width == width &&
      other.height == height &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(profileToken, codec, width, height, audio);
}

class IpCameraInfo {
  const IpCameraInfo({
    required this.kind,
    this.onvifPort,
    this.onvifPath,
    this.rtspPort = defaultRtspPort,
    this.secure = false,
    this.manufacturer,
    this.model,
    this.firmware,
    this.main,
    this.sub,
  });

  static const defaultRtspPort = 554;

  final IpCameraKind kind;

  /// The port and path of the ONVIF device service, null for a typed RTSP address
  final int? onvifPort;
  final String? onvifPath;

  /// The port of the streams on the host of the source
  final int rtspPort;

  /// RTSPS (a UniFi Protect link): played over TLS on a computer, through the console's plain port on the others
  final bool secure;
  final String? manufacturer;
  final String? model;
  final String? firmware;
  final IpCameraStreamInfo? main;
  final IpCameraStreamInfo? sub;

  /// "Reolink RLC-510A", what the camera told
  String? get label {
    final parts = [manufacturer, model].whereType<String>().where((part) => part.isNotEmpty).toList();
    if (parts.length == 2 && parts[1].toLowerCase().startsWith(parts[0].toLowerCase())) {
      return parts[1];
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'kind': kind.name,
    'onvifPort': ?onvifPort,
    'onvifPath': ?onvifPath,
    'rtspPort': rtspPort,
    if (secure) 'secure': true,
    'manufacturer': ?manufacturer,
    'model': ?model,
    'firmware': ?firmware,
    if (main != null) 'main': main!.toJson(),
    if (sub != null) 'sub': sub!.toJson(),
  };

  /// Null when [json] is not one this build reads
  static IpCameraInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final kind = IpCameraKind.values.where((value) => value.name == json['kind']).firstOrNull;
    if (kind == null) {
      return null;
    }
    String? text(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    int? port(String key) {
      final value = json[key];
      return value is int && value > 0 && value < 65536 ? value : null;
    }

    return IpCameraInfo(
      kind: kind,
      onvifPort: port('onvifPort'),
      onvifPath: text('onvifPath'),
      rtspPort: port('rtspPort') ?? defaultRtspPort,
      secure: json['secure'] == true,
      manufacturer: text('manufacturer'),
      model: text('model'),
      firmware: text('firmware'),
      main: IpCameraStreamInfo.fromJson(json['main']),
      sub: IpCameraStreamInfo.fromJson(json['sub']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IpCameraInfo &&
      other.kind == kind &&
      other.onvifPort == onvifPort &&
      other.onvifPath == onvifPath &&
      other.rtspPort == rtspPort &&
      other.secure == secure &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      other.firmware == firmware &&
      other.main == main &&
      other.sub == sub;

  @override
  int get hashCode =>
      Object.hash(kind, onvifPort, onvifPath, rtspPort, secure, manufacturer, model, firmware, main, sub);
}
