// What the pages need from a camera of another brand than Tapo: one found on the network by WS-Discovery, what its
// ONVIF services tell (the device, its profiles, the address of each stream), and the failures put into words. The
// protocol layer (lib/infrastructure/ipcam/) implements it; nothing here holds a password.

/// The failures the pages of a camera of another brand put into words (strings ip_camera_error_*)
enum IpCameraErrorKind {
  /// What the address field holds is neither an address nor an RTSP link
  badAddress,

  /// The camera asks for an account and none was given
  needsAccount,

  /// The camera refused the account
  wrongPassword,

  /// The camera only takes Basic authentication, which would hand the password in clear to whoever answers
  basicOnly,

  /// Nothing answers at the address and port
  unreachable,

  /// Something answers, but no ONVIF device service (ONVIF off, another port)
  notOnvif,

  /// The camera has no media profile, or none with a video stream
  noProfile,

  /// The stream is in a codec this device does not play (MJPEG on a phone, H.265 on iPhone and iPad)
  codecNotPlayableHere,

  /// An RTSPS address on a device whose players have no RTSPS
  secureNotHere,

  /// Anything else; the detail tells which step, never a secret
  other,
}

class IpCameraException implements Exception {
  const IpCameraException(this.kind, {this.detail, this.status});

  final IpCameraErrorKind kind;

  /// A short protocol detail (the SOAP fault code, the step), never a secret
  final String? detail;

  /// The HTTP or RTSP status, when there was one
  final int? status;

  @override
  String toString() =>
      'IpCameraException(${kind.name}${status == null ? '' : ' $status'}${detail == null ? '' : ' $detail'})';
}

/// A device that answered the WS-Discovery probe
class DiscoveredOnvifDevice {
  const DiscoveredOnvifDevice({
    required this.endpoint,
    required this.host,
    required this.port,
    required this.path,
    this.name,
    this.hardware,
    this.scopes = const [],
  });

  /// The EndpointReference address ("urn:uuid:..."): the discoveryId of the source
  final String endpoint;

  /// The host and port of its device service, from the XAddrs on the local network
  final String host;
  final int port;

  /// "/onvif/device_service"
  final String path;

  /// The name and hardware scopes, decoded, when the device tells them
  final String? name;
  final String? hardware;
  final List<String> scopes;

  /// What the list shows: its name, else its hardware, else its address
  String get label => name ?? hardware ?? host;
}

/// GetDeviceInformation
class OnvifDeviceInfo {
  const OnvifDeviceInfo({this.manufacturer, this.model, this.firmware, this.serial, this.hardwareId});

  final String? manufacturer;
  final String? model;
  final String? firmware;
  final String? serial;
  final String? hardwareId;

  /// "Reolink RLC-510A", the parts the camera told
  String? get label {
    final parts = [manufacturer, model].whereType<String>().where((part) => part.isNotEmpty).toList();
    // A manufacturer repeated at the start of the model ("HIKVISION", "HIKVISION DS-2CD...") once
    if (parts.length == 2 && parts[1].toLowerCase().startsWith(parts[0].toLowerCase())) {
      return parts[1];
    }
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// A media profile of the camera (ONVIF Media 1 GetProfiles)
class OnvifProfile {
  const OnvifProfile({
    required this.token,
    this.name,
    this.encoding,
    this.width,
    this.height,
    this.frameRate,
    this.audioEncoding,
  });

  final String token;
  final String? name;

  /// The video encoding the profile announces in upper case ("H264", "H265", "JPEG", "MPEG4"); a hint only, the SDP
  /// of the stream tells the truth (some cameras announce H264 in Media 1 for an H.265 stream)
  final String? encoding;
  final int? width;
  final int? height;
  final double? frameRate;

  /// "G711", "AAC", "G726", null without sound
  final String? audioEncoding;

  /// The number of pixels, for the choice of the main and sub stream
  int get pixels => (width ?? 0) * (height ?? 0);

  /// "H.264 1920 x 1080", or what is known of it
  String get label {
    final codec = switch (encoding) {
      'H264' => 'H.264',
      'H265' || 'HEVC' => 'H.265',
      'JPEG' => 'MJPEG',
      final String other => other,
      null => null,
    };
    final size = width != null && height != null ? '$width x $height' : null;
    return [codec, size].whereType<String>().join(' ');
  }
}

/// The main (largest) and sub (smallest other) profile of [profiles], those with a video encoder only
({OnvifProfile main, OnvifProfile? sub})? pickOnvifProfiles(List<OnvifProfile> profiles) {
  final video = profiles.where((profile) => profile.encoding != null || profile.pixels > 0).toList();
  if (video.isEmpty) {
    return null;
  }
  final sorted = [...video]..sort((a, b) => b.pixels.compareTo(a.pixels));
  final main = sorted.first;
  final sub = sorted.length > 1 && sorted.last.pixels < main.pixels ? sorted.last : null;
  return (main: main, sub: sub);
}
