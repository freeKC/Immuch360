// An ONVIF camera in memory, for the client's tests: it answers the device and media calls of ONVIF Media 1 as the
// WSDLs describe them (ver10 device, media and schema), checks the WS-Security UsernameToken against its own clock,
// may ask for HTTP Digest on top (D-Link, Dahua and Vivotek do) or for Basic only, and notes every request. The brand
// presets reproduce what public documentation and integration guides tell of each brand (ports, paths, the place of
// the media service, the clock check); every value is synthetic, nothing comes from a capture of a real device.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/infrastructure/ipcam/onvif_client.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

class FakeProfile {
  const FakeProfile(this.token, this.name, this.encoding, this.width, this.height, this.streamUri, {this.audio});

  final String token;
  final String name;
  final String? encoding;
  final int width;
  final int height;
  final String streamUri;
  final String? audio;
}

class FakeRequest {
  const FakeRequest(this.url, this.headers, this.body, this.action);

  final Uri url;
  final Map<String, String> headers;
  final String body;

  /// The local name of the first element of the Body ("GetProfiles")
  final String action;
}

class FakeOnvifCamera {
  FakeOnvifCamera({
    this.user = 'onvif',
    this.password = 'synthetic-pw',
    this.requireToken = true,
    this.requireDigest = false,
    this.basicOnly = false,
    this.clockOffset = Duration.zero,
    this.clockTolerance,
    this.devicePath = onvifDevicePath,
    this.mediaXAddr = 'http://192.0.2.200/onvif/media_service',
    this.capabilitiesFault = false,
    this.servicesFault = false,
    this.manufacturer = 'Example',
    this.model = 'Cam-1',
    this.firmware = '1.0.0',
    this.profiles = const [
      FakeProfile('main', 'mainStream', 'H264', 1920, 1080, 'rtsp://192.0.2.200:554/live/main', audio: 'G711'),
      FakeProfile('sub', 'subStream', 'H264', 640, 360, 'rtsp://192.0.2.200:554/live/sub'),
    ],
    this.snapshotUri = 'http://192.0.2.200/snapshot.jpg',
    this.digestAlgorithm = 'MD5',
    this.realm = 'ONVIF Web Service',
    DateTime? now,
  }) : now = now ?? DateTime.utc(2026, 11, 14, 12);

  final String user;
  final String password;
  final bool requireToken;
  final bool requireDigest;
  final bool basicOnly;

  /// The camera's clock minus the test's
  final Duration clockOffset;

  /// When set, a UsernameToken created further than this from the camera's clock is refused
  final Duration? clockTolerance;
  final String devicePath;

  /// What GetCapabilities and GetServices announce for the media service (any host: the client keeps its own)
  final String mediaXAddr;
  final bool capabilitiesFault;
  final bool servicesFault;
  final String manufacturer;
  final String model;
  final String firmware;
  final List<FakeProfile> profiles;
  final String? snapshotUri;
  final String digestAlgorithm;
  final String realm;

  /// The test's time
  final DateTime now;

  final requests = <FakeRequest>[];
  static const nonce = 'f00dcafe0123456789abcdef';

  OnvifPost get post =>
      (url, headers, body) async => _answer(url, headers, utf8.decode(body));

  OnvifHttpAnswer _answer(Uri url, Map<String, String> headers, String body) {
    final document = parseLiteXml(body);
    final soapBody = document.child('Envelope')?.child('Body');
    if (soapBody == null || soapBody.children.isEmpty) {
      return const OnvifHttpAnswer(400, {}, 'bad request');
    }
    final action = soapBody.children.first.name;
    requests.add(FakeRequest(url, headers, body, action));
    final authorization = headers['Authorization'];
    if (basicOnly && action != 'GetSystemDateAndTime') {
      if (authorization == null || !authorization.startsWith('Basic ')) {
        return OnvifHttpAnswer(401, {
          'www-authenticate': ['Basic realm="$realm"'],
        }, '');
      }
    }
    if (requireDigest && action != 'GetSystemDateAndTime') {
      if (authorization == null || !_digestOk(authorization, url)) {
        return OnvifHttpAnswer(401, {
          'www-authenticate': [
            'Digest realm="$realm", nonce="$nonce", algorithm=$digestAlgorithm, qop="auth", opaque="0a1b"',
          ],
        }, _fault('ter:NotAuthorized'));
      }
    }
    if (action == 'GetSystemDateAndTime') {
      return OnvifHttpAnswer(200, const {}, _envelope(_dateTime()));
    }
    if (requireToken && !_tokenOk(document)) {
      return OnvifHttpAnswer(400, const {}, _fault('ter:NotAuthorized'));
    }
    final path = url.path;
    final isDevice = path == devicePath;
    final isMedia = Uri.parse(mediaXAddr).path == path;
    switch (action) {
      case 'GetDeviceInformation' when isDevice:
        return OnvifHttpAnswer(
          200,
          const {},
          _envelope(
            '<tds:GetDeviceInformationResponse><tds:Manufacturer>$manufacturer</tds:Manufacturer>'
            '<tds:Model>$model</tds:Model><tds:FirmwareVersion>$firmware</tds:FirmwareVersion>'
            '<tds:SerialNumber>SN0000</tds:SerialNumber><tds:HardwareId>HW1</tds:HardwareId>'
            '</tds:GetDeviceInformationResponse>',
          ),
        );
      case 'GetCapabilities' when isDevice:
        if (capabilitiesFault) {
          return OnvifHttpAnswer(500, const {}, _fault('ter:ActionNotSupported'));
        }
        return OnvifHttpAnswer(
          200,
          const {},
          _envelope(
            '<tds:GetCapabilitiesResponse><tds:Capabilities>'
            '<tt:Device><tt:XAddr>http://192.0.2.200$devicePath</tt:XAddr></tt:Device>'
            '<tt:Media><tt:XAddr>$mediaXAddr</tt:XAddr><tt:StreamingCapabilities><tt:RTPMulticast>false'
            '</tt:RTPMulticast><tt:RTP_TCP>true</tt:RTP_TCP><tt:RTP_RTSP_TCP>true</tt:RTP_RTSP_TCP>'
            '</tt:StreamingCapabilities></tt:Media>'
            '</tds:Capabilities></tds:GetCapabilitiesResponse>',
          ),
        );
      case 'GetServices' when isDevice:
        if (servicesFault) {
          return OnvifHttpAnswer(500, const {}, _fault('ter:ActionNotSupported'));
        }
        return OnvifHttpAnswer(
          200,
          const {},
          _envelope(
            '<tds:GetServicesResponse>'
            '<tds:Service><tds:Namespace>http://www.onvif.org/ver10/device/wsdl</tds:Namespace>'
            '<tds:XAddr>http://192.0.2.200$devicePath</tds:XAddr></tds:Service>'
            '<tds:Service><tds:Namespace>http://www.onvif.org/ver10/media/wsdl</tds:Namespace>'
            '<tds:XAddr>$mediaXAddr</tds:XAddr></tds:Service>'
            '</tds:GetServicesResponse>',
          ),
        );
      case 'GetProfiles' when isMedia:
        return OnvifHttpAnswer(200, const {}, _envelope(_profiles()));
      case 'GetStreamUri' when isMedia:
        final token = _token(soapBody);
        final profile = profiles.where((p) => p.token == token).firstOrNull;
        if (profile == null) {
          return OnvifHttpAnswer(500, const {}, _fault('ter:NoProfile'));
        }
        return OnvifHttpAnswer(
          200,
          const {},
          _envelope(
            '<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>${_escape(profile.streamUri)}</tt:Uri>'
            '<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect><tt:InvalidAfterReboot>false'
            '</tt:InvalidAfterReboot><tt:Timeout>PT60S</tt:Timeout></trt:MediaUri></trt:GetStreamUriResponse>',
          ),
        );
      case 'GetSnapshotUri' when isMedia:
        final snapshot = snapshotUri;
        if (snapshot == null) {
          return OnvifHttpAnswer(500, const {}, _fault('ter:ActionNotSupported'));
        }
        return OnvifHttpAnswer(
          200,
          const {},
          _envelope(
            '<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>${_escape(snapshot)}</tt:Uri>'
            '</trt:MediaUri></trt:GetSnapshotUriResponse>',
          ),
        );
    }
    return OnvifHttpAnswer(400, const {}, _fault('ter:ActionNotSupported'));
  }

  String? _token(LiteXmlElement body) => body.descendantsNamed('ProfileToken').firstOrNull?.text.trim();

  bool _tokenOk(LiteXmlElement document) {
    String? text(String local) => document.descendantsNamed(local).firstOrNull?.text.trim();
    final name = text('Username');
    final digest = text('Password');
    final nonce = text('Nonce');
    final created = text('Created');
    if (name == null || digest == null || nonce == null || created == null) {
      return false;
    }
    final expected = base64.encode(
      crypto.sha1.convert([...base64.decode(nonce), ...utf8.encode(created), ...utf8.encode(password)]).bytes,
    );
    final tolerance = clockTolerance;
    if (tolerance != null) {
      final at = DateTime.tryParse(created);
      if (at == null || at.difference(now.add(clockOffset)).abs() > tolerance) {
        return false;
      }
    }
    return name == user && digest == expected;
  }

  bool _digestOk(String authorization, Uri url) {
    final params = <String, String>{
      for (final match in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(authorization))
        match.group(1)!: match.group(2) ?? match.group(3)!,
    };
    final hash = digestAlgorithm.toUpperCase().startsWith('SHA-256') ? sha256Hex : md5Hex;
    final ha1 = hash('$user:$realm:$password');
    final ha2 = hash('POST:${params['uri']}');
    final expected = hash('$ha1:$nonce:${params['nc']}:${params['cnonce']}:auth:$ha2');
    return params['username'] == user && params['response'] == expected && params['uri'] == url.path;
  }

  String _dateTime() {
    final at = now.add(clockOffset);
    return '<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType>'
        '<tt:DaylightSavings>false</tt:DaylightSavings><tt:TimeZone><tt:TZ>UTC0</tt:TZ></tt:TimeZone>'
        '<tt:UTCDateTime><tt:Time><tt:Hour>${at.hour}</tt:Hour><tt:Minute>${at.minute}</tt:Minute>'
        '<tt:Second>${at.second}</tt:Second></tt:Time><tt:Date><tt:Year>${at.year}</tt:Year>'
        '<tt:Month>${at.month}</tt:Month><tt:Day>${at.day}</tt:Day></tt:Date></tt:UTCDateTime>'
        '</tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>';
  }

  String _profiles() {
    final out = StringBuffer('<trt:GetProfilesResponse>');
    for (final profile in profiles) {
      out.write('<trt:Profiles token="${profile.token}" fixed="true"><tt:Name>${profile.name}</tt:Name>');
      out.write(
        '<tt:VideoSourceConfiguration token="vsc"><tt:Name>VideoSource</tt:Name><tt:UseCount>2</tt:UseCount>'
        '<tt:SourceToken>vs</tt:SourceToken><tt:Bounds x="0" y="0" width="1920" height="1080"/>'
        '</tt:VideoSourceConfiguration>',
      );
      final encoding = profile.encoding;
      if (encoding != null) {
        out.write(
          '<tt:VideoEncoderConfiguration token="vec_${profile.token}"><tt:Name>VideoEncoder</tt:Name>'
          '<tt:UseCount>1</tt:UseCount><tt:Encoding>$encoding</tt:Encoding><tt:Resolution>'
          '<tt:Width>${profile.width}</tt:Width><tt:Height>${profile.height}</tt:Height></tt:Resolution>'
          '<tt:Quality>4</tt:Quality><tt:RateControl><tt:FrameRateLimit>25</tt:FrameRateLimit>'
          '<tt:EncodingInterval>1</tt:EncodingInterval><tt:BitrateLimit>4096</tt:BitrateLimit></tt:RateControl>'
          '<tt:SessionTimeout>PT60S</tt:SessionTimeout></tt:VideoEncoderConfiguration>',
        );
      }
      final audio = profile.audio;
      if (audio != null) {
        out.write(
          '<tt:AudioEncoderConfiguration token="aec"><tt:Name>Audio</tt:Name><tt:UseCount>1</tt:UseCount>'
          '<tt:Encoding>$audio</tt:Encoding><tt:Bitrate>64</tt:Bitrate><tt:SampleRate>8</tt:SampleRate>'
          '</tt:AudioEncoderConfiguration>',
        );
      }
      out.write('</trt:Profiles>');
    }
    out.write('</trt:GetProfilesResponse>');
    return out.toString();
  }

  static String _fault(String subcode) => _envelope(
    '<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>$subcode</s:Value></s:Subcode></s:Code>'
    '<s:Reason><s:Text xml:lang="en">Synthetic fault</s:Text></s:Reason></s:Fault>',
  );

  static String _envelope(String body) =>
      '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
      ' xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl"'
      ' xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:ter="http://www.onvif.org/ver10/error">'
      '<s:Body>$body</s:Body></s:Envelope>';

  static String _escape(String text) => text.replaceAll('&', '&amp;');
}

/// Brand presets, from the public documentation and integration guides of each brand (listed in the lot report),
/// synthetic values: what the client has to cope with, not a capture
class FakeBrands {
  /// Hikvision: ONVIF off by default and a separate ONVIF user (Integration Protocol page); port 80; media at
  /// /onvif/Media; streams /Streaming/Channels/101 and 102; the UsernameToken checked against the camera's clock
  static FakeOnvifCamera hikvision() => FakeOnvifCamera(
    manufacturer: 'HIKVISION',
    model: 'DS-2CD0000',
    mediaXAddr: 'http://192.0.2.201/onvif/Media',
    clockOffset: const Duration(minutes: 7),
    clockTolerance: const Duration(seconds: 10),
    profiles: const [
      FakeProfile(
        'Profile_1',
        'mainStream',
        'H264',
        2560,
        1440,
        'rtsp://192.0.2.201:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1',
        audio: 'G711',
      ),
      FakeProfile(
        'Profile_2',
        'subStream',
        'H264',
        640,
        480,
        'rtsp://192.0.2.201:554/Streaming/Channels/102?transportmode=unicast&profile=Profile_2',
      ),
    ],
    snapshotUri: 'http://192.0.2.201/onvif-http/snapshot?Profile_1',
  );

  /// Dahua, Amcrest and Imou (Imou: the "safety code" as the password of admin): port 80, media at
  /// /onvif/media_service, HTTP Digest asked on top of the UsernameToken by recent firmware, streams
  /// /cam/realmonitor?channel=1&subtype=0 and 1
  static FakeOnvifCamera dahua() => FakeOnvifCamera(
    user: 'admin',
    manufacturer: 'Dahua',
    model: 'IPC-HDW0000',
    requireDigest: true,
    mediaXAddr: 'http://192.0.2.202/onvif/media_service',
    profiles: const [
      FakeProfile(
        'MediaProfile00000',
        'MediaProfile_Channel1_MainStream',
        'H265',
        2688,
        1520,
        'rtsp://192.0.2.202:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif',
        audio: 'AAC',
      ),
      FakeProfile(
        'MediaProfile00001',
        'MediaProfile_Channel1_SubStream1',
        'H264',
        704,
        576,
        'rtsp://192.0.2.202:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif',
      ),
    ],
  );

  /// Reolink wired: ONVIF on port 8000 and RTSP both off by default (Server Settings); streams
  /// /h264Preview_01_main and _sub (Preview_01_main on recent firmware)
  static FakeOnvifCamera reolink() => FakeOnvifCamera(
    user: 'admin',
    manufacturer: 'Reolink',
    model: 'RLC-000A',
    mediaXAddr: 'http://192.0.2.203:8000/onvif/media_service',
    profiles: const [
      FakeProfile('000', 'MainStream', 'H264', 2560, 1920, 'rtsp://192.0.2.203:554/h264Preview_01_main', audio: 'AAC'),
      FakeProfile('001', 'SubStream', 'H264', 640, 480, 'rtsp://192.0.2.203:554/h264Preview_01_sub'),
    ],
  );

  /// Tapo with a camera account: ONVIF on port 2020; every service at /onvif/service, GetCapabilities refused on some
  /// firmware; streams /stream1 and /stream2
  static FakeOnvifCamera tapo() => FakeOnvifCamera(
    user: 'viewer',
    manufacturer: 'tp-link',
    model: 'C510W',
    capabilitiesFault: true,
    mediaXAddr: 'http://192.0.2.204:2020/onvif/service',
    profiles: const [
      FakeProfile('profile_1', 'mainStream', 'H264', 2304, 1296, 'rtsp://192.0.2.204:554/stream1', audio: 'G711'),
      FakeProfile('profile_2', 'minorStream', 'H264', 640, 360, 'rtsp://192.0.2.204:554/stream2', audio: 'G711'),
    ],
  );

  /// Axis: ONVIF users apart from the VAPIX ones, media at /onvif/services, HTTP Digest, streams
  /// /onvif-media/media.amp?profile=...
  static FakeOnvifCamera axis() => FakeOnvifCamera(
    user: 'onvifuser',
    manufacturer: 'AXIS',
    model: 'M0000',
    requireDigest: true,
    clockOffset: const Duration(seconds: -95),
    clockTolerance: const Duration(seconds: 5),
    mediaXAddr: 'http://192.0.2.205/onvif/services',
    profiles: const [
      FakeProfile(
        'profile_1_h264',
        'profile_1 h264',
        'H264',
        1920,
        1080,
        'rtsp://192.0.2.205/onvif-media/media.amp?profile=profile_1_h264&sessiontimeout=60&streamtype=unicast',
      ),
      FakeProfile(
        'profile_1_jpeg',
        'profile_1 jpeg',
        'JPEG',
        1920,
        1080,
        'rtsp://192.0.2.205/onvif-media/media.amp?profile=profile_1_jpeg',
      ),
    ],
  );
}
