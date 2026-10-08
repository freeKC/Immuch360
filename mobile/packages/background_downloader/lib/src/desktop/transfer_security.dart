// Immuch360: the desktop transfers run in isolates of their own, each with a plain HttpClient (see
// DesktopDownloader._recreateClient), so they would see neither the certificates the app trusts on top of the
// system's, nor the client certificate of the user's server, nor the session cookie of that server, which the phones'
// native transfers take from the shared TLS configuration and cookie store of the app. The app hands them over here,
// and they travel to each task's isolate with its arguments. See IMMUCH360-NOTE.md.
//
// This file imports nothing of the downloader, so that the package's main library can export it on every platform;
// the downloader reads DesktopTransfers.

import 'dart:io';
import 'dart:typed_data';

/// The TLS material of the desktop transfers
final class DesktopTransferSecurity {
  const DesktopTransferSecurity({
    this.trustedCertificates = const [],
    this.clientCertificate,
    this.clientCertificatePassword,
  });

  /// Certificates to trust on top of the system's, PEM or DER
  final List<Uint8List> trustedCertificates;

  /// A PKCS#12 file holding the client certificate and its private key
  final Uint8List? clientCertificate;
  final String? clientCertificatePassword;

  bool get isEmpty => trustedCertificates.isEmpty && clientCertificate == null;

  /// A context with the system's roots and this material; null when there is nothing to add, so that the client
  /// keeps dart:io's default context
  SecurityContext? createContext() {
    if (isEmpty) {
      return null;
    }
    final context = SecurityContext(withTrustedRoots: true);
    for (final certificate in trustedCertificates) {
      context.setTrustedCertificatesBytes(certificate);
    }
    final clientCertificate = this.clientCertificate;
    if (clientCertificate != null) {
      context
        ..useCertificateChainBytes(
          clientCertificate,
          password: clientCertificatePassword,
        )
        ..usePrivateKeyBytes(
          clientCertificate,
          password: clientCertificatePassword,
        );
    }
    return context;
  }
}

/// What the app configured for the transfers of this isolate
abstract final class DesktopTransfers {
  static DesktopTransferSecurity? security;
  static Map<String, String> Function(Uri url)? headersFor;

  /// Changes at each configuration, so that the downloader rebuilds its client before the next use
  static int version = 0;
}

/// Sets what the desktop transfers of this isolate use from now on: [security] for their TLS connections, and
/// [headersFor], called in this isolate when a task starts, for headers that the task's own headers do not carry (the
/// session cookie of the task's server). A task already running keeps what it started with.
void configureDesktopTransfers({
  DesktopTransferSecurity? security,
  Map<String, String> Function(Uri url)? headersFor,
}) {
  DesktopTransfers.security = security;
  DesktopTransfers.headersFor = headersFor;
  DesktopTransfers.version++;
}
