// The MIME types of the device's decoders (Android's MediaCodecList), asked once per run of the app and kept: the
// choice of a film's player reads them before each film (film_player_choice.dart). The list does not change while the
// app runs. Elsewhere (iOS, the computers) and on a build whose platform side does not answer, the list is null: the
// device's player is then chosen, as before release 46.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _log = Logger('DeviceDecoderTypes');

/// Reads the list from the platform: the MIME types in lower case, null when the platform does not tell
typedef DecoderTypesReader = Future<Set<String>?> Function();

class DeviceDecoderTypes {
  DeviceDecoderTypes({DecoderTypesReader? read}) : _read = read ?? _readFromAndroid;

  static const channel = MethodChannel('immuch360/media_decoders');

  final DecoderTypesReader _read;
  Future<Set<String>?>? _types;

  /// The MIME types of the device's decoders, read at the first call only; a failed read is tried again at the next
  /// call
  Future<Set<String>?> types() {
    final cached = _types;
    if (cached != null) {
      return cached;
    }
    final read = _types = _read().then((types) {
      if (types == null) {
        _types = null;
      }
      return types;
    });
    return read;
  }

  static Future<Set<String>?> _readFromAndroid() async {
    try {
      final types = await channel.invokeListMethod<String>('mimeTypes');
      return types == null ? null : {for (final type in types) type.toLowerCase()};
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      _log.warning('The decoders of the device could not be listed: ${error.code}');
      return null;
    }
  }
}
