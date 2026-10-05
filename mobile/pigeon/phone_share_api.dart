import 'package:pigeon/pigeon.dart';

// Phones only: "Share this phone on the network". The read-only WebDAV server runs in Dart; the platforms give it the
// files of the gallery and keep the share alive (Android foreground service, iOS screen kept awake).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/phone_share_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/phoneshare/PhoneShare.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.phoneshare'),
    swiftOut: 'ios/Runner/Core/PhoneShare.g.swift',
    // PigeonError is already declared by Messages.g.swift in the same Runner target
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// What a PROPFIND tells of a file without opening it. [size] is 0 when the platform does not tell (the headset then
/// learns the real size from the first read), [modifiedMs] the modification date in milliseconds since the epoch.
class PhoneShareFileInfo {
  const PhoneShareFileInfo({
    required this.assetId,
    required this.size,
    required this.mimeType,
    required this.fileName,
    required this.modifiedMs,
  });

  final String assetId;
  final int size;
  final String mimeType;
  final String fileName;
  final int modifiedMs;
}

/// A file of the gallery that Dart can open with RandomAccessFile: the media itself when its path is readable, else a
/// copy in the cache ([isTemporary]), deleted by [PhoneShareApi.releaseTemporaryFiles].
class PhoneShareOpenedFile {
  const PhoneShareOpenedFile({required this.path, required this.size, required this.isTemporary});

  final String path;
  final int size;
  final bool isTemporary;
}

@HostApi()
abstract class PhoneShareApi {
  /// Android: starts the foreground service with its notification ([title], [text], and the [stopLabel] of its Stop
  /// action). iOS: keeps the screen awake.
  void startKeepAlive(String title, String text, String stopLabel);

  /// The text of the notification once the address changed (Android; nothing on iOS)
  void updateKeepAlive(String text);

  void stopKeepAlive();

  /// The size, MIME type, name and date of each asset found among [assetIds], in one platform query per chunk; an
  /// asset gone from the gallery is left out.
  @async
  List<PhoneShareFileInfo> fileInfos(List<String> assetIds);

  /// A readable path for the asset [assetId], or null when it is gone or not on the device (iCloud only).
  @async
  PhoneShareOpenedFile? openFile(String assetId);

  /// Deletes the copies made by [openFile]; called when the share stops.
  void releaseTemporaryFiles();
}

@FlutterApi()
abstract class PhoneShareEvents {
  /// The Stop action of the Android notification
  void stopRequested();
}
