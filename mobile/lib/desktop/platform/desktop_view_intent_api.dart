import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';
import 'package:path/path.dart' as p;

/// ViewIntentHostApi on the computers: "Open with Immuch360 Desktop" and a file dropped on the program arrive as paths
/// on the command line (main_desktop.dart), where Android delivers a view intent
class DesktopViewIntentHostApi implements ViewIntentHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  static final _pending = <String>[];

  /// Keeps the files of the command line, handed over one by one as Android hands over its intents
  static void addLaunchPaths(Iterable<String> paths) => _pending.addAll(paths.where((path) => path.isNotEmpty));

  @override
  Future<ViewIntentPayload?> consumeViewIntent() async {
    if (_pending.isEmpty) {
      return null;
    }
    final path = _pending.removeAt(0);
    return ViewIntentPayload(path: path, mimeType: mimeTypeOf(path));
  }

  /// The MIME type the view intent handler expects, from the extension: a computer gives no type with a path
  static String mimeTypeOf(String path) => switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' || '.insp' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    '.heic' || '.heif' => 'image/heic',
    '.dng' => 'image/x-adobe-dng',
    '.mp4' || '.insv' || '.360' || '.osv' || '.lrv' => 'video/mp4',
    '.mov' => 'video/quicktime',
    '.mkv' => 'video/x-matroska',
    '.webm' => 'video/webm',
    _ => 'application/octet-stream',
  };
}
