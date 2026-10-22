// The cameras the tracker can use, and which one it takes by default: never an infrared camera. Many laptops show their
// Windows Hello infrared camera as a second video camera ("USB2.0 IR UVC WebCam" next to "USB2.0 FHD UVC WebCam" on
// the owner's); its grey night picture would track badly and light the infrared emitters for nothing. A name says it
// most of the time; a camera taken by default is also opened with HeadTrackerOptions.colourOnly, so that one whose
// formats are all grey is refused before it streams, whatever its name ([HeadCamera.greyOnly] once known).
//
// Among the others, the default prefers a camera on the screen side or of unknown place (a USB webcam) to a virtual
// camera (OBS, Phone Link, NVIDIA Broadcast: a picture that may be no camera at all) and to the rear camera of a
// tablet, which both look like a broken tracker ("Face not found"). The menu still lists them all.

import 'dart:convert';

/// Where a camera sits on the computer, from the ACPI physical location Windows has for its device
enum HeadCameraPanel {
  /// Not known: a USB webcam, or a computer that does not say
  unknown,

  /// The screen side of a laptop or a tablet
  front,

  /// The rear of a tablet
  back,

  /// Another side (top, bottom, left, right)
  other,
}

/// A video camera as Media Foundation lists it
class HeadCamera {
  const HeadCamera({
    required this.id,
    required this.name,
    this.panel = HeadCameraPanel.unknown,
    this.virtualCamera = false,
    this.greyOnly = false,
  });

  /// Its symbolic link, which opens it
  final String id;

  /// Its friendly name, for the camera menu
  final String name;

  /// Where it sits ([panel] from the device, else what its name says)
  final HeadCameraPanel panel;

  /// A camera of the virtual camera API, or one whose name says it is virtual
  final bool virtualCamera;

  /// Its formats are all grey: found when it was refused as the default camera
  final bool greyOnly;

  /// The name says infrared, or its formats are grey: never the default, still in the menu for whoever wants it
  bool get infrared => greyOnly || looksInfrared(name);

  /// This camera, known to give grey pictures only
  HeadCamera asGreyOnly() => HeadCamera(id: id, name: name, panel: panel, virtualCamera: virtualCamera, greyOnly: true);

  /// How far down the default choice it comes: the screen side or a USB webcam first, a virtual camera next, the rear
  /// camera last
  int get defaultRank {
    if (panel == HeadCameraPanel.back || looksRear(name)) {
      return 2;
    }
    if (virtualCamera || looksVirtual(name)) {
      return 1;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) => other is HeadCamera && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'HeadCamera($name${infrared ? ', infrared' : ''}${panel == HeadCameraPanel.unknown ? '' : ', ${panel.name}'}'
      '${virtualCamera ? ', virtual' : ''})';
}

/// "IR" as a word, or infrared, Windows Hello, depth: the names infrared and depth sensors go by
final _infraredName = RegExp(r'(^|[^a-z0-9])ir([^a-z0-9]|$)|infra.?red|windows hello|\bdepth\b', caseSensitive: false);

/// The names of virtual cameras and of the apps that make them
final _virtualName = RegExp(
  r'virtual|\bobs\b|nvidia broadcast|snap camera|xsplit|manycam|droidcam|epoccam|iriun|reincubate|connected camera',
  caseSensitive: false,
);

/// The names of rear cameras ("Microsoft Camera Rear" on a Surface)
final _rearName = RegExp(r'\b(rear|back)\b', caseSensitive: false);

/// Whether a camera's name says it is an infrared (or depth) camera
bool looksInfrared(String name) => _infraredName.hasMatch(name);

/// Whether a camera's name says it is a virtual camera
bool looksVirtual(String name) => _virtualName.hasMatch(name);

/// Whether a camera's name says it is a rear camera
bool looksRear(String name) => _rearName.hasMatch(name);

/// The camera the tracker takes when the user chose none: never an infrared one, the first of the best
/// [HeadCamera.defaultRank]; null when there is none (an infrared camera only is used when the user picks it). [except]:
/// ids already refused for this start.
HeadCamera? defaultHeadCamera(Iterable<HeadCamera> cameras, {Set<String> except = const {}}) {
  HeadCamera? best;
  for (final camera in cameras) {
    if (camera.infrared || except.contains(camera.id)) {
      continue;
    }
    if (best == null || camera.defaultRank < best.defaultRank) {
      best = camera;
    }
  }
  return best;
}

HeadCameraPanel _panelOf(Object? value) => switch (value) {
  'front' => HeadCameraPanel.front,
  'back' => HeadCameraPanel.back,
  'top' || 'bottom' || 'left' || 'right' => HeadCameraPanel.other,
  _ => HeadCameraPanel.unknown,
};

/// The cameras of the JSON of ht_list_cameras
List<HeadCamera> parseHeadCameras(String json) {
  final list = jsonDecode(json);
  if (list is! List) {
    return const [];
  }
  return [
    for (final item in list)
      if (item is Map && item['id'] is String && (item['id'] as String).isNotEmpty)
        HeadCamera(
          id: item['id'] as String,
          name: item['name'] is String ? item['name'] as String : '',
          panel: _panelOf(item['panel']),
          virtualCamera: item['virtual'] == true,
        ),
  ];
}
