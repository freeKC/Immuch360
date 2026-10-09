// The certificate files the user picks on a computer: the client certificate (PKCS #12) and the trusted
// certificates. The system's file dialog comes through file_selector's platform interface, whose Windows, Linux and
// macOS implementations the app already has through image_picker, so that no plugin is added to the phone builds.

import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';

/// Picks a file and reads it; null when the user gives up
typedef PickFileBytes = Future<Uint8List?> Function();

Future<Uint8List?> _pick(String label, List<String> extensions) async {
  final file = await FileSelectorPlatform.instance.openFile(
    acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
  );
  return file?.readAsBytes();
}

/// A client certificate with its private key, as the phones import it
Future<Uint8List?> pickPkcs12File() => _pick('PKCS #12', const ['p12', 'pfx']);

/// A certificate to trust, PEM or DER, under the names Windows, browsers and servers give them
Future<Uint8List?> pickCertificateFile() => _pick('X.509', const ['pem', 'crt', 'cer', 'der']);
