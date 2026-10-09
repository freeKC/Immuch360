import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/platform/network_api.g.dart';

/// NetworkApi on the computers. There is no native client whose address could be handed to Dart: NetworkRepository
/// asks DesktopHttpStack directly, and this class passes what the settings pages and ApiService ask of the API to
/// that stack.
class DesktopNetworkApi implements NetworkApi {
  DesktopNetworkApi({this._stack});

  final DesktopHttpStack? _stack;

  // The app's stack is read at the call, not at the construction, which happens when the platform provider loads
  DesktopHttpStack get _http => _stack ?? DesktopHttpStack.instance;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// Checks and keeps the PKCS#12 file; fails with the TLS library's error when the file or the password is wrong,
  /// as the Android KeyStore and SecPKCS12Import refuse them
  @override
  Future<void> addCertificate(ClientCertData clientData) =>
      _http.setClientCertificate(clientData.data, clientData.password);

  /// The Android system picker has no counterpart: on a computer the certificate is imported from a file
  /// (importClientCertificate), which ends in [addCertificate]
  @override
  Future<void> selectCertificate(ClientCertPrompt promptText) =>
      Future.error(PlatformException(code: 'unsupported', message: 'Import the certificate file on a computer'));

  @override
  Future<void> removeCertificate() => _http.removeClientCertificate();

  @override
  Future<bool> hasCertificate() async => _http.hasClientCertificate;

  /// Never asked on a computer (NetworkRepository uses DesktopHttpStack there): 0 is no client
  @override
  Future<int> getClientPointer() async => 0;

  @override
  Future<void> setRequestHeaders(Map<String, String> headers, List<String> serverUrls, String? token) =>
      _http.setRequestHeaders(headers, serverUrls, token);

  /// The app group of the iOS widgets: none on a computer
  @override
  Future<String> getAppGroupId() async => '';
}
