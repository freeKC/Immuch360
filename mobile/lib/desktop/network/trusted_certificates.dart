// "Trusted certificates" of the computers. On a phone a server behind a private certificate authority works once the
// authority is installed in the system, because the native clients trust the system's store. On a computer dart:io
// trusts the system's roots too (the Windows certificate stores, the bundle of the Linux distribution), but a user
// often cannot or will not add an authority to the whole system for one app, and a self signed server never is in
// it. So the app keeps its own list, which every HTTPS client of the app trusts on top of the system's: the Immich
// stack, the shares (WebDAV and the other clients built with a plain HttpClient, through DesktopHttpOverrides) and
// the desktop transfers of the vendored background_downloader. Nothing ever accepts a certificate without checking
// it: an added certificate is an anchor of the usual checks, host name included.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('TrustedCertificates');

/// One certificate the user trusts
@immutable
class TrustedCertificate {
  const TrustedCertificate._({
    required this.pem,
    required this.der,
    required this.fingerprint,
    required this.subject,
    required this.notAfter,
  });

  /// The certificate alone, as one PEM block
  final String pem;
  final Uint8List der;

  /// SHA-256 of [der] in lower case hexadecimal: the identity of the certificate in the list and its file name
  final String fingerprint;

  /// The common name of the subject, else its organisation, else null
  final String? subject;
  final DateTime? notAfter;

  /// The fingerprint as people compare it: upper case pairs separated by colons
  String get displayFingerprint {
    final pairs = [for (var i = 0; i < fingerprint.length; i += 2) fingerprint.substring(i, i + 2)];
    return pairs.join(':').toUpperCase();
  }

  static TrustedCertificate? fromDer(Uint8List der) {
    final details = _CertificateDetails.read(der);
    if (details == null) {
      return null;
    }
    final body = base64.encode(der);
    final lines = [for (var i = 0; i < body.length; i += 64) body.substring(i, (i + 64).clamp(0, body.length))];
    return TrustedCertificate._(
      pem: '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n',
      der: der,
      fingerprint: sha256.convert(der).toString(),
      subject: details.subject,
      notAfter: details.notAfter,
    );
  }

  @override
  bool operator ==(Object other) => other is TrustedCertificate && other.fingerprint == fingerprint;

  @override
  int get hashCode => fingerprint.hashCode;
}

final _pemBlock = RegExp(r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----');

/// The certificates of a file the user picked: the PEM blocks it holds ("Base-64 encoded X.509" of the Windows
/// export, .pem, .crt), or the certificate itself when the file is binary ("DER encoded binary X.509", .cer).
/// Empty when the file holds none.
List<TrustedCertificate> readCertificates(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  // A DER certificate starts with a SEQUENCE; a PEM file is text
  if (data.isNotEmpty && data.first == 0x30) {
    final certificate = TrustedCertificate.fromDer(data);
    if (certificate != null) {
      return [certificate];
    }
  }
  final text = latin1.decode(data, allowInvalid: true);
  final found = <TrustedCertificate>[];
  for (final match in _pemBlock.allMatches(text)) {
    try {
      final der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
      final certificate = TrustedCertificate.fromDer(der);
      if (certificate != null && !found.contains(certificate)) {
        found.add(certificate);
      }
    } on FormatException {
      continue;
    }
  }
  return found;
}

/// The list of trusted certificates, kept as one PEM file each in the support folder of the app
class TrustedCertificates extends ChangeNotifier {
  TrustedCertificates({Future<Directory> Function()? folder}) : _folder = folder ?? _defaultFolder;

  /// One list for the app; each isolate that starts the HTTP stack reads it from the files
  static final instance = TrustedCertificates();

  final Future<Directory> Function() _folder;
  List<TrustedCertificate> _certificates = const [];
  SecurityContext? _context;
  bool _loaded = false;

  static Future<Directory> _defaultFolder() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'trusted_certificates'));

  List<TrustedCertificate> get certificates => _certificates;

  /// The context every HTTPS client of the app gets when it gives none: the system's roots and the user's
  /// certificates. Null while the user trusts nothing more, so that the clients keep dart:io's default context.
  SecurityContext? get context {
    if (_certificates.isEmpty) {
      return null;
    }
    return _context ??= newContext();
  }

  /// A new context with the system's roots and the user's certificates, for a client that adds its own certificate
  SecurityContext newContext() {
    final context = SecurityContext(withTrustedRoots: true);
    for (final certificate in _certificates) {
      try {
        context.setTrustedCertificatesBytes(utf8.encode(certificate.pem));
      } on TlsException catch (error) {
        // Checked when it was added; a certificate BoringSSL refuses later must not take the others down
        _log.warning('A trusted certificate was refused: ${error.message}');
      }
    }
    return context;
  }

  /// Reads the files once; later calls do nothing
  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final folder = await _folder();
      if (!folder.existsSync()) {
        return;
      }
      final found = <TrustedCertificate>[];
      for (final entry in folder.listSync()) {
        if (entry is! File || p.extension(entry.path) != '.pem') {
          continue;
        }
        for (final certificate in readCertificates(await entry.readAsBytes())) {
          if (!found.contains(certificate)) {
            found.add(certificate);
          }
        }
      }
      _set(found);
    } catch (error, stack) {
      _log.warning('Could not read the trusted certificates', error, stack);
    }
  }

  /// Adds the certificates of a file the user picked; the ones added, empty when the file had only known ones.
  /// A [FormatException] when the file holds no certificate, a [TlsException] when the TLS library refuses one.
  Future<List<TrustedCertificate>> add(List<int> fileBytes) async {
    final read = readCertificates(fileBytes);
    if (read.isEmpty) {
      throw const FormatException('No certificate in this file');
    }
    // What the TLS library will refuse is refused here, before anything is written
    for (final certificate in read) {
      SecurityContext(withTrustedRoots: false).setTrustedCertificatesBytes(utf8.encode(certificate.pem));
    }
    final added = [
      for (final certificate in read)
        if (!_certificates.contains(certificate)) certificate,
    ];
    if (added.isEmpty) {
      return added;
    }
    final folder = await _folder();
    await folder.create(recursive: true);
    for (final certificate in added) {
      final file = File(p.join(folder.path, '${certificate.fingerprint}.pem'));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(certificate.pem, flush: true);
      await temporary.rename(file.path);
    }
    _set([..._certificates, ...added]);
    return added;
  }

  Future<void> remove(TrustedCertificate certificate) async {
    final file = File(p.join((await _folder()).path, '${certificate.fingerprint}.pem'));
    if (file.existsSync()) {
      await file.delete();
    }
    _set([
      for (final kept in _certificates)
        if (kept != certificate) kept,
    ]);
  }

  void _set(List<TrustedCertificate> certificates) {
    _certificates = List.unmodifiable(certificates);
    _context = null;
    notifyListeners();
  }
}

/// Gives the trusted certificates to every HttpClient of the isolate built without a context of its own: the shares
/// (WebDAV, DLNA, the bridge's reads), http.Client(), the image providers. Clients that bring their own context, like
/// the Tapo cameras' certificate check, keep it.
class DesktopHttpOverrides extends HttpOverrides {
  DesktopHttpOverrides(this._certificates);

  final TrustedCertificates _certificates;

  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context ?? _certificates.context);
}

/// The subject and the end of validity of a DER certificate, read with a small DER reader: enough for the list the
/// user sees, nothing that the TLS checks rest on
class _CertificateDetails {
  const _CertificateDetails(this.subject, this.notAfter);

  final String? subject;
  final DateTime? notAfter;

  static const _commonName = [0x55, 0x04, 0x03];
  static const _organisation = [0x55, 0x04, 0x0a];

  static _CertificateDetails? read(Uint8List der) {
    try {
      final certificate = _Der(der, 0);
      if (certificate.tag != 0x30 || certificate.end != der.length) {
        return null;
      }
      final tbs = certificate.children().first;
      final fields = tbs.children().toList();
      // An explicit version comes first as [0]
      final offset = fields.isNotEmpty && fields.first.tag == 0xa0 ? 1 : 0;
      if (fields.length < offset + 6) {
        return null;
      }
      final validity = fields[offset + 3].children().toList();
      final subject = fields[offset + 4];
      if (validity.length != 2 || subject.tag != 0x30) {
        return null;
      }
      return _CertificateDetails(
        _attribute(subject, _commonName) ?? _attribute(subject, _organisation),
        _time(validity[1]),
      );
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The value of the attribute [oid] in a Name: SEQUENCE of SET of SEQUENCE { OID, value }
  static String? _attribute(_Der name, List<int> oid) {
    for (final set in name.children()) {
      for (final pair in set.children()) {
        final parts = pair.children().toList();
        if (parts.length == 2 && parts[0].tag == 0x06 && listEquals(parts[0].value, oid)) {
          return _string(parts[1]);
        }
      }
    }
    return null;
  }

  static String? _string(_Der value) => switch (value.tag) {
    // UTF8String, PrintableString, IA5String, T61String
    0x0c || 0x13 || 0x16 || 0x14 => utf8.decode(value.value, allowMalformed: true),
    // BMPString: UTF-16 big endian
    0x1e => String.fromCharCodes([
      for (var i = 0; i + 1 < value.value.length; i += 2) (value.value[i] << 8) | value.value[i + 1],
    ]),
    _ => null,
  };

  /// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ)
  static DateTime? _time(_Der value) {
    final text = ascii.decode(value.value);
    final full = switch (value.tag) {
      0x17 when text.length >= 12 => '${int.parse(text.substring(0, 2)) >= 50 ? '19' : '20'}$text',
      0x18 when text.length >= 14 => text,
      _ => null,
    };
    if (full == null) {
      return null;
    }
    return DateTime.utc(
      int.parse(full.substring(0, 4)),
      int.parse(full.substring(4, 6)),
      int.parse(full.substring(6, 8)),
      int.parse(full.substring(8, 10)),
      int.parse(full.substring(10, 12)),
      int.parse(full.substring(12, 14)),
    );
  }
}

/// One DER element in [_bytes] at [_start]
class _Der {
  _Der(this._bytes, this._start) {
    tag = _bytes[_start];
    var length = _bytes[_start + 1];
    var header = 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) {
        throw const FormatException('Unsupported DER length');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _bytes[_start + 2 + i];
      }
      header += count;
    }
    _valueStart = _start + header;
    end = _valueStart + length;
    if (end > _bytes.length) {
      throw const FormatException('Truncated DER');
    }
  }

  final Uint8List _bytes;
  final int _start;
  late final int tag;
  late final int _valueStart;
  late final int end;

  Uint8List get value => Uint8List.sublistView(_bytes, _valueStart, end);

  Iterable<_Der> children() sync* {
    var position = _valueStart;
    while (position < end) {
      final child = _Der(_bytes, position);
      yield child;
      position = child.end;
    }
  }
}
