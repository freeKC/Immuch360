// View on a big screen, on a Meta Quest: an ordinary photo or video opened whole on a large flat screen of the
// immersive viewer, larger than the 2D window shows it, the screen movable and resizable with the grips. An idea of
// Gaurav Mukherjee (gmfun/Immuch360, branch quest/flat-3d, commit 502779b0b). The viewer gets it as the bigScreen JSON
// (see BigScreenRequest).

import 'dart:convert';

/// The kind and the version of the bigScreen JSON, see [BigScreenRequest]
const bigScreenKind = 'bigScreen';
const bigScreenVersion = 1;

/// What the immersive viewer of the Meta Quest is asked for an ordinary photo or video opened with View on a big
/// screen: the bigScreen JSON of the stereoPair parameter of ImmersiveApi.open (BigScreenSpec on the side of the
/// viewer), frozen in test/fixtures/ai_immersive/big_screen_contract_v1.json. A photo goes on the stereo quad as one
/// picture, a video on the flat video screen. A viewer that does not know the request shows the photo flat on the quad,
/// and the video on the sphere.
class BigScreenRequest {
  const BigScreenRequest();

  Map<String, Object> toJson() => {'kind': bigScreenKind, 'version': bigScreenVersion};

  /// The stereoPair JSON of ImmersiveApi.open
  String toJsonString() => jsonEncode(toJson());

  /// The request [json] holds, null for another kind or version
  static BigScreenRequest? fromJson(Object? json) {
    if (json is! Map || json['kind'] != bigScreenKind || json['version'] != bigScreenVersion) {
      return null;
    }
    return const BigScreenRequest();
  }

  @override
  bool operator ==(Object other) => other is BigScreenRequest;

  @override
  int get hashCode => bigScreenKind.hashCode;

  @override
  String toString() => 'BigScreenRequest()';
}
