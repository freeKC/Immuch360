// The clipboard of the system for photos and videos on a computer ("Copy" of a right click, Control C or Command C):
// the files themselves, which a file manager, a mail, a chat program or an editor takes as attachments, and for a single
// photo the picture too, which an image editor or a chat box pastes. Flutter's own clipboard holds text only (it serves
// "Copy name"), so the files and the picture go through the channel immuch360/clipboard of the runners:
// - Windows (windows/runner/clipboard_channel.cpp): CF_HDROP with "Preferred DropEffect" set to copy, so that Explorer
//   copies rather than moves, and for a photo CF_DIB (24 bits, which every program reads) and "PNG";
// - Linux (linux/runner/clipboard_channel.cc, GTK): text/uri-list and x-special/gnome-copied-files ("copy" then the
//   URIs, what Nautilus, Nemo and Caja paste), and for a photo image/png; the app serves them while it runs, as every
//   X11 and Wayland program does, so they go with it unless a clipboard manager kept them;
// - macOS (macos/Runner/MainFlutterWindow.swift): one pasteboard item per file with its file URL, the first also with
//   public.png and public.tiff for a photo, which the runner makes itself from the file (ImageIO reads HEIC too).
// The picture for Windows and Linux is decoded here by the engine's own codecs (JPEG, PNG, GIF, WebP, BMP and what the
// system adds), at most [clipboardPictureMaxPixels]; a photo the engine cannot decode is copied as its file only.
//
// Each write gives a token, which tells later whether the clipboard still holds what the app put there: the sequence
// number of the Windows clipboard, the change count of the macOS pasteboard, a count of the writes of this run on
// Linux while the app still owns the selection. The copies of remote files are kept while it does
// (clipboard_copies.dart).

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopClipboard');

/// The channel of the runners of the three computers
const desktopClipboardChannel = MethodChannel('immuch360/clipboard');

/// The error code of a writeFiles that a later one overtook in the runner (macOS makes the picture off its main
/// thread): nothing was written, the later write stands
const clipboardSupersededCode = 'superseded';

/// The largest picture put on the clipboard, in pixels: a larger photo is scaled down for its picture (its file stays
/// whole). 40 megapixels keep the photos of most cameras and 8K 360° photos at their size, under 200 MB decoded.
const clipboardPictureMaxPixels = 40 * 1000 * 1000;

/// The picture of a single photo, in the forms the clipboard of this computer takes
@immutable
class ClipboardPicture {
  const ClipboardPicture({this.png, this.dib, this.sourcePath});

  /// The picture as a PNG: "PNG" on Windows, image/png on Linux
  final Uint8List? png;

  /// The picture as a device independent bitmap, header and pixels: CF_DIB on Windows
  final Uint8List? dib;

  /// The file the runner reads the picture from itself: macOS
  final String? sourcePath;
}

/// What the clipboard is given: [paths], files of this computer, and for one photo its [picture]
@immutable
class ClipboardPayload {
  const ClipboardPayload({required this.paths, this.picture});

  final List<String> paths;
  final ClipboardPicture? picture;

  /// The arguments of writeFiles on the channel
  Map<String, Object?> toArguments() => {
    'paths': paths,
    if (picture?.png != null) 'png': picture!.png,
    if (picture?.dib != null) 'dib': picture!.dib,
    if (picture?.sourcePath != null) 'imagePath': picture!.sourcePath,
  };
}

/// The clipboard of the system, as the copy of photos and videos uses it
abstract interface class DesktopClipboard {
  /// Puts [payload] on the clipboard in place of what it held; the token of the write for [holds]. Throws a
  /// [PlatformException] when the system refused it.
  Future<int> writeFiles(ClipboardPayload payload);

  /// Whether the clipboard may still hold the write of [token]: false once something else was copied, here or in
  /// another program; true when the runner cannot tell, so that no copy goes while it may still be pasted
  Future<bool> holds(int token);

  /// Puts [text] on the clipboard (Copy name)
  Future<void> writeText(String text);
}

/// The clipboard through the runners' channel, and Flutter's for text
class ChannelDesktopClipboard implements DesktopClipboard {
  const ChannelDesktopClipboard({this._channel = desktopClipboardChannel});

  final MethodChannel _channel;

  @override
  Future<int> writeFiles(ClipboardPayload payload) async {
    final token = await _channel.invokeMethod<int>('writeFiles', payload.toArguments());
    if (token == null) {
      throw PlatformException(code: 'clipboard', message: 'The runner gave no token');
    }
    return token;
  }

  @override
  Future<bool> holds(int token) async {
    try {
      return await _channel.invokeMethod<bool>('holds', {'token': token}) ?? false;
    } on PlatformException catch (error) {
      _log.warning('Could not ask the clipboard what it holds: ${error.message}');
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> writeText(String text) => Clipboard.setData(ClipboardData(text: text));
}

/// The picture of the photo at [path], whose bytes [encoded] reads, for the clipboard of [platform] (this computer by default): the runner reads the
/// file at [path] itself on macOS; elsewhere the engine decodes it, at most [maxPixels], into a PNG, and on Windows a
/// bitmap too. Null when the engine cannot decode it: the photo is then copied as its file only.
Future<ClipboardPicture?> clipboardPictureOf(
  String path,
  Future<Uint8List> Function() encoded, {
  TargetPlatform? platform,
  int maxPixels = clipboardPictureMaxPixels,
}) async {
  final target = platform ?? defaultTargetPlatform;
  if (target == TargetPlatform.macOS) {
    return ClipboardPicture(sourcePath: path);
  }
  try {
    final image = await _decode(await encoded(), maxPixels);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        return null;
      }
      Uint8List? dib;
      if (target == TargetPlatform.windows) {
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        if (rgba == null) {
          return null;
        }
        dib = await _dibInBackground(rgba.buffer.asUint8List(), image.width, image.height);
      }
      return ClipboardPicture(png: png.buffer.asUint8List(), dib: dib);
    } finally {
      image.dispose();
    }
  } on Exception catch (error) {
    _log.info('No picture on the clipboard for a photo the engine does not decode: $error');
    return null;
  } on Error catch (error) {
    // A file far too large for the memory left
    _log.info('No picture on the clipboard: $error');
    return null;
  }
}

/// [dibOfRgba] in another isolate. Its own function, so that the closure sent there holds only the pixels and the
/// size, never the engine objects of the caller, which cannot be sent.
Future<Uint8List> _dibInBackground(Uint8List rgba, int width, int height) {
  final pixels = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() => dibOfRgba(pixels.materialize().asUint8List(), width, height));
}

/// [bytes] decoded by the engine, scaled down to [maxPixels] at most
Future<ui.Image> _decode(Uint8List bytes, int maxPixels) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    final pixels = descriptor.width * descriptor.height;
    final scale = pixels > maxPixels ? math.sqrt(maxPixels / pixels) : 1.0;
    final codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? math.max(1, (descriptor.width * scale).floor()) : null,
      targetHeight: scale < 1 ? math.max(1, (descriptor.height * scale).floor()) : null,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

/// The size of the header of a CF_DIB: a BITMAPINFOHEADER
const dibHeaderSize = 40;

/// [rgba], [width] by [height] pixels of four bytes (red, green, blue, alpha, not premultiplied), as a CF_DIB: a
/// BITMAPINFOHEADER then the rows from the bottom one up, three bytes a pixel in blue, green, red order, each row padded
/// to four bytes. 24 bits since that is what every program of Windows reads; a transparent pixel is laid on white, as
/// Windows' own programs show it. Top-level: it runs in an isolate.
Uint8List dibOfRgba(Uint8List rgba, int width, int height) {
  final stride = (width * 3 + 3) & ~3;
  final imageSize = stride * height;
  final out = Uint8List(dibHeaderSize + imageSize);
  final header = ByteData.sublistView(out, 0, dibHeaderSize);
  header
    ..setUint32(0, dibHeaderSize, Endian.little)
    ..setInt32(4, width, Endian.little)
    // Positive: the rows go from the bottom up
    ..setInt32(8, height, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    // BI_RGB
    ..setUint32(16, 0, Endian.little)
    ..setUint32(20, imageSize, Endian.little)
    // 72 dots an inch, in dots a metre
    ..setInt32(24, 2835, Endian.little)
    ..setInt32(28, 2835, Endian.little)
    ..setUint32(32, 0, Endian.little)
    ..setUint32(36, 0, Endian.little);
  for (var y = 0; y < height; y++) {
    final from = y * width * 4;
    var to = dibHeaderSize + (height - 1 - y) * stride;
    for (var x = 0; x < width; x++) {
      final pixel = from + x * 4;
      final alpha = rgba[pixel + 3];
      int over(int channel) => alpha == 255 ? channel : (channel * alpha + 255 * (255 - alpha) + 127) ~/ 255;
      out[to] = over(rgba[pixel + 2]);
      out[to + 1] = over(rgba[pixel + 1]);
      out[to + 2] = over(rgba[pixel]);
      to += 3;
    }
  }
  return out;
}

/// Whether the copy of photos and videos to the clipboard of the system is offered here: the three computers, never a
/// phone, a tablet, a TV or a headset
bool get desktopClipboardOffered => CurrentPlatform.isDesktop;
