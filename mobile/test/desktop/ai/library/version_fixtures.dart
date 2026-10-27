// The XMP of a 3D photo made from an original, as the conversions write it, for the tests of the library: what makes a
// file a version, whatever its name.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// The SHA-1 of [bytes] in base64, as the checksum column of the library and Immich write it
String sha1Base64(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

/// The packet of a version of the original whose bytes are [original]
StereoPhotoXmp versionXmp(List<int> original, {String name = 'salon.jpg', int quarterTurns = 0}) =>
    StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: name,
      sourceSize: original.length,
      sourceSha1: sha1Base64(original),
      sourceQuarterTurns: quarterTurns,
      created: '2026-10-27T10:12:00+01:00',
      creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
    );
