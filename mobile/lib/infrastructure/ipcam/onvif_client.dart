// A small ONVIF client of our own, read only: the device service (GetSystemDateAndTime, GetDeviceInformation,
// GetCapabilities, GetServices when GetCapabilities fails) and the media service of ONVIF Media 1 (GetProfiles,
// GetStreamUri, GetSnapshotUri). Nothing else is ever sent: no PTZ, no setting, no event subscription, nothing that
// writes to the camera. Written from the ONVIF Core and Media specifications and WSDLs (ver10); the behaviour of
// python-onvif-zeep (MIT) was read for the clock offset of the UsernameToken, no code taken.
//
// Authentication, the way the cameras ask for it:
// - WS-Security UsernameToken with PasswordDigest (Base64(SHA-1(nonce + created + password))), "created" at the time
//   of the camera (its GetSystemDateAndTime, answered without an account), so that a camera whose clock is off by
//   minutes does not refuse a right password (Hikvision, Axis check it). Never PasswordText.
// - HTTP Digest when the camera answers 401 with a Digest challenge (D-Link and Vivotek ask for both layers on the
//   same request): MD5, MD5-sess, SHA-256. Never Basic: a camera that offers Basic only is told so (basicOnly).
// - No account at all until the camera asks for one; one try of the account per call, a refusal is never tried again
//   on its own.
//
// The addresses a camera gives (its service XAddrs, its stream and snapshot URIs) keep their port, path and query,
// with the host of the source in place of theirs: a camera behind a NAT or with a stale address in its settings
// announces another one, and the account goes to the host the user chose and to no other. The user info of a URI is
// dropped. Nothing of a request or an answer is logged, the addresses masked (camera_address.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('OnvifClient');

/// The usual place of the device service
const onvifDevicePath = '/onvif/device_service';

/// The ports tried for a typed address without one, in order: the default, Reolink, Tapo, then common others
const onvifCandidatePorts = [80, 8000, 2020, 8080, 8899];

/// Largest SOAP answer read
const onvifMaxAnswerBytes = 512 * 1024;

/// An HTTP answer of the camera
class OnvifHttpAnswer {
  const OnvifHttpAnswer(this.status, this.headers, this.body);

  final int status;

  /// Names in lower case, every value of a header given several times
  final Map<String, List<String>> headers;
  final String body;
}

/// Posts [body] to [url] with [headers]: always a Content-Length, never chunked, no redirect followed. Throws
/// [IpCameraException] unreachable. Injectable for the tests.
typedef OnvifPost = Future<OnvifHttpAnswer> Function(Uri url, Map<String, String> headers, List<int> body);

/// The real [OnvifPost]: dart:io, one connection per request
OnvifPost onvifHttpPost({Duration timeout = const Duration(seconds: 4)}) => (url, headers, body) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..autoUncompress = true
    ..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.postUrl(url).timeout(timeout);
    request
      ..followRedirects = false
      ..persistentConnection = false
      ..contentLength = body.length;
    headers.forEach(request.headers.set);
    request.add(body);
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > onvifMaxAnswerBytes) {
        throw const IpCameraException(IpCameraErrorKind.other, detail: 'answer too large');
      }
    }
    final answerHeaders = <String, List<String>>{};
    response.headers.forEach((name, values) => answerHeaders[name.toLowerCase()] = values);
    return OnvifHttpAnswer(response.statusCode, answerHeaders, utf8.decode(bytes, allowMalformed: true));
  } on SocketException {
    throw const IpCameraException(IpCameraErrorKind.unreachable);
  } on TimeoutException {
    throw const IpCameraException(IpCameraErrorKind.unreachable, detail: 'timeout');
  } on HttpException {
    throw const IpCameraException(IpCameraErrorKind.notOnvif, detail: 'HTTP');
  } finally {
    client.close(force: true);
  }
};

/// The services a camera announces, on the host of the source
class OnvifServices {
  const OnvifServices({required this.media, this.recording, this.search, this.replay});

  final Uri media;

  /// Profile G, when the camera has it (not used in this version: recordings of other brands come later)
  final Uri? recording;
  final Uri? search;
  final Uri? replay;
}

/// What the client learned of a camera, for the add page
class OnvifCameraReading {
  const OnvifCameraReading({
    required this.device,
    required this.services,
    required this.profiles,
    required this.clockOffset,
    required this.usedHttpDigest,
  });

  final OnvifDeviceInfo device;
  final OnvifServices services;
  final List<OnvifProfile> profiles;

  /// The camera's clock minus this device's
  final Duration clockOffset;

  /// The camera asked for HTTP Digest on top of the UsernameToken
  final bool usedHttpDigest;
}

class OnvifClient {
  OnvifClient({
    required this.host,
    this.port = 80,
    this.path = onvifDevicePath,
    this.user = '',
    this.password = '',
    OnvifPost? post,
    DateTime Function()? now,
    @visibleForTesting List<int> Function()? nonce,
  }) : _post = post ?? onvifHttpPost(),
       _now = now ?? DateTime.now,
       _nonce = nonce ?? _randomNonce;

  /// The host of the source: every request and every address the camera gives go to it
  final String host;
  final int port;
  final String path;
  final String user;
  final String password;
  final OnvifPost _post;
  final DateTime Function() _now;
  final List<int> Function() _nonce;

  Duration _clockOffset = Duration.zero;
  bool _clockRead = false;

  /// The HTTP Digest challenge of the camera, answered on each next request once it asked
  RtspDigest? _digest;

  bool get _hasAccount => user.isNotEmpty;

  Uri get deviceUrl => Uri(scheme: 'http', host: host, port: port, path: path);

  /// Reads the camera: its clock, its device information, its services, its profiles. Throws [IpCameraException].
  Future<OnvifCameraReading> read() async {
    await readClock();
    final device = await deviceInformation();
    final services = await this.services();
    final profiles = await this.profiles(services.media);
    return OnvifCameraReading(
      device: device,
      services: services,
      profiles: profiles,
      clockOffset: _clockOffset,
      usedHttpDigest: _digest != null,
    );
  }

  /// GetSystemDateAndTime, without an account (the specification allows it before authentication): the offset of
  /// the camera's clock, used for the "created" time of each UsernameToken. A camera that refuses it (or answers
  /// without a UTC time) leaves the offset at zero.
  Future<void> readClock() async {
    _clockRead = true;
    try {
      final body = await _call(
        deviceUrl,
        _deviceNs,
        'GetSystemDateAndTime',
        '<tds:GetSystemDateAndTime/>',
        auth: false,
      );
      final utc = _first(body, 'UTCDateTime');
      final date = utc == null ? null : _first(utc, 'Date');
      final time = utc == null ? null : _first(utc, 'Time');
      int? n(LiteXmlElement? parent, String name) => int.tryParse(_text(parent, name) ?? '');
      final year = n(date, 'Year');
      final month = n(date, 'Month');
      final day = n(date, 'Day');
      if (year == null || month == null || day == null) {
        return;
      }
      final camera = DateTime.utc(
        year,
        month,
        day,
        n(time, 'Hour') ?? 0,
        n(time, 'Minute') ?? 0,
        n(time, 'Second') ?? 0,
      );
      _clockOffset = camera.difference(_now().toUtc());
    } on IpCameraException catch (error) {
      if (error.kind == IpCameraErrorKind.unreachable || error.kind == IpCameraErrorKind.notOnvif) {
        rethrow;
      }
      _log.fine('The camera did not tell its time: ${error.kind.name}');
    }
  }

  /// GetDeviceInformation
  Future<OnvifDeviceInfo> deviceInformation() async {
    final body = await _call(deviceUrl, _deviceNs, 'GetDeviceInformation', '<tds:GetDeviceInformation/>');
    final answer = _first(body, 'GetDeviceInformationResponse') ?? body;
    String? text(String name) {
      final value = _text(answer, name)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return OnvifDeviceInfo(
      manufacturer: text('Manufacturer'),
      model: text('Model'),
      firmware: text('FirmwareVersion'),
      serial: text('SerialNumber'),
      hardwareId: text('HardwareId'),
    );
  }

  /// The media service and the Profile G ones: GetCapabilities, else GetServices, else the device service itself
  /// (Tapo serves every service on one address)
  Future<OnvifServices> services() async {
    try {
      final body = await _call(
        deviceUrl,
        _deviceNs,
        'GetCapabilities',
        '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>',
      );
      Uri? xaddr(String section) {
        final element = _first(body, section);
        return element == null ? null : _onHost(_text(element, 'XAddr'));
      }

      final media = xaddr('Media');
      if (media != null) {
        return OnvifServices(
          media: media,
          recording: xaddr('Recording'),
          search: xaddr('Search'),
          replay: xaddr('Replay'),
        );
      }
    } on IpCameraException catch (error) {
      if (error.kind == IpCameraErrorKind.wrongPassword || error.kind == IpCameraErrorKind.unreachable) {
        rethrow;
      }
      _log.fine('GetCapabilities failed (${error.kind.name}): asking GetServices');
    }
    try {
      final body = await _call(
        deviceUrl,
        _deviceNs,
        'GetServices',
        '<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>',
      );
      Uri? service(String namespace) {
        for (final element in _all(body, 'Service')) {
          if (_text(element, 'Namespace')?.trim() == namespace) {
            return _onHost(_text(element, 'XAddr'));
          }
        }
        return null;
      }

      final media = service(_mediaNs);
      if (media != null) {
        return OnvifServices(
          media: media,
          recording: service('http://www.onvif.org/ver10/recording/wsdl'),
          search: service('http://www.onvif.org/ver10/search/wsdl'),
          replay: service('http://www.onvif.org/ver10/replay/wsdl'),
        );
      }
    } on IpCameraException catch (error) {
      if (error.kind == IpCameraErrorKind.wrongPassword || error.kind == IpCameraErrorKind.unreachable) {
        rethrow;
      }
      _log.fine('GetServices failed (${error.kind.name}): the device service is asked for the media');
    }
    return OnvifServices(media: deviceUrl);
  }

  /// GetProfiles of ONVIF Media 1, the profiles without a video encoder left out. Throws noProfile when none is left.
  Future<List<OnvifProfile>> profiles(Uri media) async {
    final body = await _call(media, _mediaNs, 'GetProfiles', '<trt:GetProfiles/>');
    final profiles = <OnvifProfile>[];
    for (final element in _all(body, 'Profiles')) {
      final token = element.attributes['token'];
      if (token == null || token.isEmpty) {
        continue;
      }
      final video = _first(element, 'VideoEncoderConfiguration');
      final audio = _first(element, 'AudioEncoderConfiguration');
      final resolution = video == null ? null : _first(video, 'Resolution');
      final encoding = video == null ? null : _text(video, 'Encoding')?.trim().toUpperCase();
      if (video == null || encoding == null || encoding.isEmpty) {
        continue;
      }
      final rate = video.descendantsNamed('FrameRateLimit').firstOrNull;
      profiles.add(
        OnvifProfile(
          token: token,
          name: _text(element, 'Name', direct: true)?.trim(),
          encoding: encoding,
          width: int.tryParse(_text(resolution, 'Width') ?? ''),
          height: int.tryParse(_text(resolution, 'Height') ?? ''),
          frameRate: double.tryParse(rate?.text.trim() ?? ''),
          audioEncoding: audio == null ? null : _text(audio, 'Encoding')?.trim().toUpperCase(),
        ),
      );
    }
    if (profiles.isEmpty) {
      throw const IpCameraException(IpCameraErrorKind.noProfile);
    }
    return profiles;
  }

  /// GetStreamUri of [profile], RTP unicast over RTSP: the address on the host of the source, without user info
  Future<CameraStreamAddress> streamUri(Uri media, String profile) async {
    final body = await _call(
      media,
      _mediaNs,
      'GetStreamUri',
      '<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP'
          '</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>${_escape(profile)}</trt:ProfileToken>'
          '</trt:GetStreamUri>',
    );
    final uri = _text(_first(body, 'MediaUri'), 'Uri')?.trim();
    final address = uri == null ? null : parseCameraStreamAddress(uri);
    if (address == null) {
      throw const IpCameraException(IpCameraErrorKind.noProfile, detail: 'no RTSP address');
    }
    return CameraStreamAddress(
      secure: address.secure,
      host: host,
      port: address.port,
      pathAndQuery: address.pathAndQuery,
    );
  }

  /// GetSnapshotUri of [profile]: the address on the host of the source, without user info; null when the camera has
  /// none
  Future<String?> snapshotUri(Uri media, String profile) async {
    try {
      final body = await _call(
        media,
        _mediaNs,
        'GetSnapshotUri',
        '<trt:GetSnapshotUri><trt:ProfileToken>${_escape(profile)}</trt:ProfileToken></trt:GetSnapshotUri>',
      );
      final uri = _onHost(_text(_first(body, 'MediaUri'), 'Uri'));
      return uri?.toString();
    } on IpCameraException catch (error) {
      if (error.kind == IpCameraErrorKind.unreachable) {
        rethrow;
      }
      return null;
    }
  }

  /// [text] as an http(s) address on the host of the source (its port, path and query kept), null when it is not one
  Uri? _onHost(String? text) {
    final parsed = Uri.tryParse(text?.trim() ?? '');
    if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https') || parsed.host.isEmpty) {
      return null;
    }
    return parsed.replace(host: host, userInfo: '');
  }

  static const _deviceNs = 'http://www.onvif.org/ver10/device/wsdl';
  static const _mediaNs = 'http://www.onvif.org/ver10/media/wsdl';

  /// One SOAP call: the body of the answer's Body. [auth]: with the UsernameToken when an account was given.
  Future<LiteXmlElement> _call(Uri url, String namespace, String action, String body, {bool auth = true}) async {
    if (auth && _hasAccount && !_clockRead) {
      await readClock();
    }
    final envelope = utf8.encode(_envelope(body, auth: auth && _hasAccount));
    final headers = {
      'Content-Type': 'application/soap+xml; charset=utf-8; action="$namespace/$action"',
      'Accept': 'application/soap+xml, text/xml',
      'User-Agent': 'Immuch360',
    };
    var answer = await _send(url, headers, envelope);
    if (answer.status == 401) {
      final challenges = answer.headers['www-authenticate'] ?? const [];
      final digest = RtspDigest.of(challenges);
      if (digest == null) {
        final basic = challenges.any((value) => value.toLowerCase().startsWith('basic'));
        throw IpCameraException(basic ? IpCameraErrorKind.basicOnly : IpCameraErrorKind.wrongPassword, status: 401);
      }
      if (!_hasAccount) {
        throw const IpCameraException(IpCameraErrorKind.needsAccount, status: 401);
      }
      // The first challenge, or a nonce that only went stale (RFC 7616 3.3): once more. Any other refusal of an
      // answer with the account is not tried again: it counts towards a lockout on some cameras.
      final stale = challenges.any((value) => RegExp(r'stale\s*=\s*"?true', caseSensitive: false).hasMatch(value));
      if (_digest == null || stale) {
        _digest = digest;
        answer = await _send(url, headers, envelope);
      }
      if (answer.status == 401) {
        throw const IpCameraException(IpCameraErrorKind.wrongPassword, status: 401);
      }
    }
    final soapBody = parseLiteXml(answer.body).child('Envelope')?.child('Body');
    if (soapBody == null) {
      throw IpCameraException(
        answer.status == 200 ? IpCameraErrorKind.other : IpCameraErrorKind.notOnvif,
        status: answer.status,
        detail: 'not SOAP',
      );
    }
    final fault = soapBody.child('Fault');
    if (fault != null) {
      final codes = [
        ...fault.descendantsNamed('Value'),
        ...fault.descendantsNamed('faultcode'),
      ].map((e) => e.text.trim()).toList();
      final reason =
          fault.descendantsNamed('Text').firstOrNull?.text ??
          fault.descendantsNamed('faultstring').firstOrNull?.text ??
          '';
      final notAuthorized =
          codes.any((code) => code.endsWith('NotAuthorized') || code.endsWith('FailedAuthentication')) ||
          reason.toLowerCase().contains('not authorized');
      if (notAuthorized) {
        throw IpCameraException(
          _hasAccount && auth ? IpCameraErrorKind.wrongPassword : IpCameraErrorKind.needsAccount,
          status: answer.status,
        );
      }
      final code = codes.lastOrNull?.split(':').last;
      throw IpCameraException(IpCameraErrorKind.other, status: answer.status, detail: '$action ${code ?? 'fault'}');
    }
    if (answer.status != 200) {
      throw IpCameraException(IpCameraErrorKind.notOnvif, status: answer.status, detail: action);
    }
    return soapBody;
  }

  Future<OnvifHttpAnswer> _send(Uri url, Map<String, String> headers, List<int> envelope) {
    final digest = _digest;
    final requestHeaders = {
      ...headers,
      if (digest != null)
        'Authorization': digest.authorization(
          'POST',
          url.hasQuery ? '${url.path}?${url.query}' : (url.path.isEmpty ? '/' : url.path),
          user,
          password,
        ),
    };
    return _post(url, requestHeaders, envelope);
  }

  String _envelope(String body, {required bool auth}) {
    final created = _now().toUtc().add(_clockOffset);
    final header = auth ? '<s:Header>${usernameToken(user, password, created, _nonce())}</s:Header>' : '';
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:tds="$_deviceNs" xmlns:trt="$_mediaNs" xmlns:tt="http://www.onvif.org/ver10/schema">'
        '$header<s:Body>$body</s:Body></s:Envelope>';
  }

  static List<int> _randomNonce() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256));
  }
}

/// The WS-Security header of a request: the UsernameToken with its PasswordDigest, Base64(SHA-1(nonce + created +
/// password)) (WS-Security UsernameToken Profile 1.0, section 3.1; ONVIF Core 5.12.2), [created] in UTC to the second
String usernameToken(String user, String password, DateTime created, List<int> nonce) {
  final stamp = '${created.toUtc().toIso8601String().split('.').first.replaceAll(RegExp(r'Z$'), '')}Z';
  final digest = base64.encode(crypto.sha1.convert([...nonce, ...utf8.encode(stamp), ...utf8.encode(password)]).bytes);
  return '<wsse:Security s:mustUnderstand="1"'
      ' xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"'
      ' xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
      '<wsse:UsernameToken><wsse:Username>${_escape(user)}</wsse:Username>'
      '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0'
      '#PasswordDigest">$digest</wsse:Password>'
      '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0'
      '#Base64Binary">${base64.encode(nonce)}</wsse:Nonce>'
      '<wsu:Created>$stamp</wsu:Created></wsse:UsernameToken></wsse:Security>';
}

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

LiteXmlElement? _first(LiteXmlElement? parent, String local) => parent?.descendantsNamed(local).firstOrNull;

Iterable<LiteXmlElement> _all(LiteXmlElement parent, String local) => parent.descendantsNamed(local);

/// The text of the first [local] under [parent] (its direct children only with [direct])
String? _text(LiteXmlElement? parent, String local, {bool direct = false}) {
  if (parent == null) {
    return null;
  }
  final elements = direct ? parent.childrenNamed(local) : parent.descendantsNamed(local);
  return elements.firstOrNull?.text;
}
