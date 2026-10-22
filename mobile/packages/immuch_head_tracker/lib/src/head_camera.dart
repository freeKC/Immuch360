// The cameras the tracker can use, and which one it takes by default: never an infrared camera. Many laptops show their
// Windows Hello infrared camera as a second video camera ("USB2.0 IR UVC WebCam" next to "USB2.0 FHD UVC WebCam" on
// the owner's); its grey night picture would track badly and light the infrared emitters for nothing.

import 'dart:convert';

/// A video camera as Media Foundation lists it
class HeadCamera {
  const HeadCamera({required this.id, required this.name});

  /// Its symbolic link, which opens it
  final String id;

  /// Its friendly name, for the camera menu
  final String name;

  /// The name says infrared: never the default, still in the menu for whoever wants it
  bool get infrared => looksInfrared(name);

  @override
  bool operator ==(Object other) => other is HeadCamera && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'HeadCamera($name${infrared ? ', infrared' : ''})';
}

/// "IR" as a word, or infrared, Windows Hello, depth: the names infrared and depth sensors go by
final _infraredName = RegExp(
  r'(^|[^a-z0-9])ir([^a-z0-9]|$)|infra.?red|windows hello|\bdepth\b',
  caseSensitive: false,
);

/// Whether a camera's name says it is an infrared (or depth) camera
bool looksInfrared(String name) => _infraredName.hasMatch(name);

/// The camera the tracker takes when the user chose none: the first one that is not infrared, null when there is
/// none (an infrared camera only is used when the user picks it)
HeadCamera? defaultHeadCamera(Iterable<HeadCamera> cameras) {
  for (final camera in cameras) {
    if (!camera.infrared) {
      return camera;
    }
  }
  return null;
}

/// The cameras of the JSON of ht_list_cameras
List<HeadCamera> parseHeadCameras(String json) {
  final list = jsonDecode(json);
  if (list is! List) {
    return const [];
  }
  return [
    for (final item in list)
      if (item is Map &&
          item['id'] is String &&
          (item['id'] as String).isNotEmpty)
        HeadCamera(
          id: item['id'] as String,
          name: item['name'] is String ? item['name'] as String : '',
        ),
  ];
}
