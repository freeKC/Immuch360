import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/passkey_api.g.dart';

/// PasskeyHostApi on the computers: the passkeys of upstream are off in Immuch360 (kPasskeysAvailable), and a computer
/// has no system passkey prompt behind this channel, so it answers "not supported" and never shows a prompt
class DesktopPasskeyHostApi implements PasskeyHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<String?> register(String options) async => null;

  @override
  Future<String?> authenticate(String options) async => null;
}
