import 'package:pigeon/pigeon.dart';

// Phones only: the scanner of "Connect a TV or computer", which reads the QR code a big screen shows to be signed in
// (sign in with your phone). ZXing on Android (no Google Play services), AVFoundation on iOS. The text read is handed
// to Dart as it is, and goes to no log.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/qr_scan_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/pairing/QrScan.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.pairing'),
    swiftOut: 'ios/Runner/Core/QrScan.g.swift',
    // PigeonError is already declared by Messages.g.swift in the same Runner target
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum QrScanStatus {
  /// [QrScanResult.text] holds what the code says
  scanned,

  /// The user closed the scanner
  cancelled,

  /// The camera permission was refused
  permissionDenied,

  /// The device has no camera
  noCamera,

  /// Another scan is open, or the camera could not start
  failed,
}

class QrScanResult {
  const QrScanResult({required this.status, this.text});

  final QrScanStatus status;
  final String? text;
}

@HostApi()
abstract class QrScanApi {
  /// Opens the scanner with [prompt] over the viewfinder, until a QR code is read or the user closes it; [cancelLabel]
  /// names the button that closes it on iOS (Android has its Back)
  @async
  QrScanResult scan(String prompt, String cancelLabel);
}
