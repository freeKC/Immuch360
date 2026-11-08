import 'package:pigeon/pigeon.dart';

// The native decoder of the encoded images that Flutter's engine does not decode with its own codecs, Android only:
// HEIF, AVIF, the raw files, JPEG XL. The engine would hand them to Android's ImageDecoder at their full size, and abort
// the app on an OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026); this decoder bounds the size and
// turns every failure into an error of the call (see encoded_image_probe.dart). iOS and the computers keep the engine
// and never call it (pigeon-not-on-desktop.json). Its FlutterError class is the one of LocalImages.g.kt, in the same
// package.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/native_image_decode_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/images/NativeImageDecode.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.images', includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class NativeImageDecodeApi {
  /// The encoded image of [length] bytes at the native address [pointer], which stays the caller's, decoded to RGBA at
  /// most [maxWidth] x [maxHeight] pixels (0 for no bound on that side), its aspect ratio kept and upright: the
  /// address of the pixels (the caller frees it), their width, height and row bytes. A failure, an OutOfMemoryError
  /// included, is the error UndecodableImage with the class and the message of the cause.
  @async
  Map<String, int> decodeEncoded(int pointer, int length, int maxWidth, int maxHeight);
}
