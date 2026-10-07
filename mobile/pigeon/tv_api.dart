import 'package:pigeon/pigeon.dart';

// Android only: Android TV and Google TV. Whether the device is a TV, read once before the first frame, and the native
// text dialog that replaces the Flutter text fields there (the Gboard TV keyboard cannot be driven with the remote in
// a Flutter field, Flutter issue 177360).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/tv_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/tv/Tv.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.tv'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// [isTelevision]: Android TV or Google TV (the leanback feature, or the television UI mode of boxes that do not
/// declare it), never a Meta Quest. [isLowRamDevice]: what ActivityManager.isLowRamDevice tells.
class TvDeviceInfo {
  const TvDeviceInfo({required this.isTelevision, required this.isLowRamDevice});

  final bool isTelevision;
  final bool isLowRamDevice;
}

/// What a text field takes, for the keyboard of the native dialog
enum TvTextKind { text, url, email, password, number }

/// The native text dialog: its [title], the [text] it starts with, and the labels of its buttons
class TvTextRequest {
  const TvTextRequest({
    required this.title,
    required this.text,
    required this.kind,
    required this.okLabel,
    required this.cancelLabel,
  });

  final String title;
  final String text;
  final TvTextKind kind;
  final String okLabel;
  final String cancelLabel;
}

@HostApi()
abstract class TvApi {
  TvDeviceInfo deviceInfo();

  /// Shows a native text dialog over the app and returns what the user typed, or null when cancelled
  @async
  String? editText(TvTextRequest request);
}
