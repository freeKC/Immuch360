// One viewing of a splat in the splat viewer of the computers, phones and tablets (lot SV1 of the splat viewer): the
// generated media the media bridge serves under a random id, on the bridge's own origin (http://127.0.0.1:<port>,
// a secure context, no CORS):
//
//   GET  /<token>/<s>/index.html and the page's modules, Spark and three.js   from the app's assets, in memory
//   GET  /<token>/<s>/session.json                                            what the page needs, in the app's words
//   GET  /<token>/<s>/scene.spz | scene.ply                                   a file of this device, from disk
//   POST /<token>/<s>/events                                                  what the page tells the app
//   POST /<token>/<s>/poster                                                  the view captured for Save to Immich
//   GET  /<token>/<s>/save                                                    where that save stands
//
// A file of a share keeps its own bridge URL (/<token>/<source>/<path>), on the same origin. The page is served with
// a Content-Security-Policy that lets it load nothing but the app's own origin (no runtime download: every script is
// in the app), its one inline script (the import map) allowed by its hash; the scene and the session are never cached
// (no-store), so that no web view keeps a copy of a splat of 150 MB.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

/// The folder of the page in the app's assets
const splatViewerAssetFolder = 'assets/splat_viewer';

/// The files of the page, served under each session: the page, its modules, Spark and three.js
const splatViewerPageFiles = [
  'index.html',
  'viewer.css',
  'viewer.js',
  'session.js',
  'placement.js',
  'controls.js',
  'drawloop.js',
  'panel.js',
  'events.js',
  'save.js',
  'mark.js',
  'adapt.js',
  'framewatch.js',
  'engine-spark.js',
  'spark.module.min.js',
  'spark_rs_bg.wasm',
  'three.module.min.js',
  'three.core.min.js',
  'Pass.js',
];

/// The content type of a file of the page: module scripts are refused under any other than text/javascript
String splatViewerContentType(String name) {
  final dot = name.lastIndexOf('.');
  return switch (dot < 0 ? '' : name.substring(dot)) {
    '.html' => 'text/html; charset=utf-8',
    '.js' => 'text/javascript; charset=utf-8',
    '.css' => 'text/css; charset=utf-8',
    '.wasm' => 'application/wasm',
    '.json' => 'application/json; charset=utf-8',
    _ => 'application/octet-stream',
  };
}

/// The Content-Security-Policy of the page whose index.html is [indexHtml]: the app's own origin only, WebAssembly
/// compiled from the bytes the page fetched, Spark's workers from blobs, and the import map (the one inline script)
/// by its hash
String splatViewerCsp(String indexHtml) {
  final importMap = RegExp(r'<script type="importmap">(.*?)</script>', dotAll: true).firstMatch(indexHtml)?.group(1);
  final hash = importMap == null ? '' : " 'sha256-${base64.encode(sha256.convert(utf8.encode(importMap)).bytes)}'";
  return "default-src 'none'; script-src 'self' 'wasm-unsafe-eval' blob:$hash; worker-src 'self' blob: data:; "
      "connect-src 'self'; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; font-src 'self'";
}

/// The page's files from [bundle], [splatViewerPageFiles] by name
Future<Map<String, Uint8List>> loadSplatViewerPage(AssetBundle bundle) async {
  final files = <String, Uint8List>{};
  for (final name in splatViewerPageFiles) {
    final data = await bundle.load('$splatViewerAssetFolder/$name');
    files[name] = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
  return files;
}

/// A random id of 16 bytes, in hex: a session is only served by the id the app registered
String newSplatViewerSessionId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(16, (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// What the page tells the app (events.js), parsed from its JSON
sealed class SplatViewerEvent {
  const SplatViewerEvent();

  /// The event of [json], null for one this app does not know
  static SplatViewerEvent? parse(Map<String, Object?> json) => switch (json['type']) {
    'ready' => SplatViewerReady(json),
    'upright' when json['value'] is String => SplatViewerUpright(json['value']! as String),
    'gyroscope' => SplatViewerGyroscope(on: json['on'] == true),
    'stats' => SplatViewerStats(json),
    'unsupported' => SplatViewerUnsupported('${json['reason']}'),
    'error' => SplatViewerError('${json['message']}'),
    'close' => const SplatViewerClose(),
    'watch' => SplatViewerWatch(json),
    'reduce' when json['keep'] is int && (json['keep']! as int) > 0 => SplatViewerReduce(json['keep']! as int),
    'keepWhole' => const SplatViewerKeepWhole(),
    'save' => SplatViewerSave(album: json['album'] != false),
    'saveAgain' => SplatViewerSave(album: json['album'] != false, again: true),
    'cancelSave' => const SplatViewerCancelSave(),
    _ => null,
  };
}

/// Save to Immich of the page's panel: the user pressed Save ([again] for "Save another copy"), with the album or not
final class SplatViewerSave extends SplatViewerEvent {
  const SplatViewerSave({required this.album, this.again = false});

  final bool album;
  final bool again;
}

/// The user closed the panel of Save to Immich, or pressed its Cancel while it ran
final class SplatViewerCancelSave extends SplatViewerEvent {
  const SplatViewerCancelSave();
}

/// Save to Immich in the page (plan of 3 November 2026, section 6.1), given by the app: what session.json says of it,
/// the poster the page captured, and where the save stands
abstract class SplatViewerSaving {
  /// The "save" entry of session.json: offered, the album switch, the texts of the panel
  Map<String, Object?> get session;

  /// The JPEG the page captured; false when it is none the writer takes
  bool takePoster(Uint8List jpeg);

  /// The user's answer in the panel (the events save, saveAgain and cancelSave)
  void onEvent(SplatViewerEvent event);

  /// The orientation the user chose in the page, kept with the scene
  void upright(String value);

  /// {state, percent, text, assetId}
  Map<String, Object?> state();
}

/// The most bytes of the poster the page posts: a JPEG of 1,600 px at quality 85 is about 300 KB
const splatViewerPosterMaxBytes = 2 << 20;

/// Whether [bytes] start as a JPEG and hold a frame (a SOF marker in their first 64 KiB)
bool isSplatViewerPoster(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return false;
  }
  final end = bytes.length < 65536 ? bytes.length - 1 : 65535;
  for (var i = 2; i < end; i++) {
    if (bytes[i] == 0xFF) {
      final marker = bytes[i + 1];
      if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        return true;
      }
    }
  }
  return false;
}

/// The scene shows: how long it took, what drew it, and where the page placed it
final class SplatViewerReady extends SplatViewerEvent {
  const SplatViewerReady(this.fields);

  final Map<String, Object?> fields;

  int? get loadMs => (fields['loadMs'] as num?)?.toInt();
  int? get gaussians => (fields['gaussians'] as num?)?.toInt();
  String? get renderer => fields['renderer'] as String?;
  double? get nonBlank => (fields['nonBlank'] as num?)?.toDouble();
}

/// The user chose an orientation with Turn upright: 'yUp', 'zUp' or 'yDown'
final class SplatViewerUpright extends SplatViewerEvent {
  const SplatViewerUpright(this.value);

  final String value;
}

final class SplatViewerGyroscope extends SplatViewerEvent {
  const SplatViewerGyroscope({required this.on});

  final bool on;
}

/// How the frames went over the last seconds of drawing
final class SplatViewerStats extends SplatViewerEvent {
  const SplatViewerStats(this.fields);

  final Map<String, Object?> fields;

  double? get fps => (fields['fps'] as num?)?.toDouble();
}

/// The web view cannot draw splats: 'webgl2' or 'simd'
final class SplatViewerUnsupported extends SplatViewerEvent {
  const SplatViewerUnsupported(this.reason);

  final String reason;
}

final class SplatViewerError extends SplatViewerEvent {
  const SplatViewerError(this.message);

  final String message;
}

/// The page's Back or Esc: the host closes the viewer
final class SplatViewerClose extends SplatViewerEvent {
  const SplatViewerClose();
}

/// What the page found in the first frames of a computer (framewatch.js): slow or not, the frame rate, and the count
/// it offers when slow
final class SplatViewerWatch extends SplatViewerEvent {
  const SplatViewerWatch(this.fields);

  final Map<String, Object?> fields;

  bool get slow => fields['slow'] == true;
  double? get fps => (fields['fps'] as num?)?.toDouble();
  int? get keep => (fields['keep'] as num?)?.toInt();
}

/// The user took the reduced copy the page offered, of [keep] gaussians
final class SplatViewerReduce extends SplatViewerEvent {
  const SplatViewerReduce(this.keep);

  final int keep;
}

/// The user kept every gaussian when the page offered a reduced copy
final class SplatViewerKeepWhole extends SplatViewerEvent {
  const SplatViewerKeepWhole();
}

/// The generated media of one viewing: [page] (from [loadSplatViewerPage]), [session] written as session.json, and
/// [scene] (a file of this device, served as scene.spz or scene.ply) when the scene is not a file of a share. The
/// events the page posts come out of [onEvent]; anything else posted is refused.
class SplatViewerSession implements GeneratedMedia, GeneratedMediaSink, GeneratedMediaLargePosts {
  SplatViewerSession({
    required this.id,
    required Map<String, Uint8List> page,
    required Map<String, Object?> session,
    this.scene,
    this.sceneName,
    required this.onEvent,
    this.saving,
  }) : _page = page,
       _session = Uint8List.fromList(utf8.encode(jsonEncode(session))),
       _csp = splatViewerCsp(utf8.decode(page['index.html'] ?? Uint8List(0), allowMalformed: true));

  final String id;
  final Map<String, Uint8List> _page;
  final Uint8List _session;
  final String _csp;

  /// The file of this device the page fetches as [sceneName] ("scene.spz", "scene.ply")
  final File? scene;
  final String? sceneName;

  final void Function(SplatViewerEvent event) onEvent;

  /// Save to Immich, when the app offers it for this scene
  final SplatViewerSaving? saving;

  static const _noStore = {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'};

  @override
  GeneratedFile? file(String name) {
    final scene = this.scene;
    if (scene != null && name == sceneName) {
      return GeneratedFile.disk(scene, 'application/octet-stream', headers: _noStore);
    }
    if (name == 'session.json') {
      return GeneratedFile(_session, splatViewerContentType(name), headers: _noStore);
    }
    final saving = this.saving;
    if (name == 'save' && saving != null) {
      return GeneratedFile(
        Uint8List.fromList(utf8.encode(jsonEncode(saving.state()))),
        splatViewerContentType('save.json'),
        headers: _noStore,
      );
    }
    final bytes = _page[name];
    if (bytes == null) {
      return null;
    }
    return GeneratedFile(
      bytes,
      splatViewerContentType(name),
      headers: {
        'X-Content-Type-Options': 'nosniff',
        if (name == 'index.html') 'Content-Security-Policy': _csp,
        if (name == 'index.html') 'Referrer-Policy': 'no-referrer',
      },
    );
  }

  @override
  int postLimit(String name) =>
      name == 'poster' && saving != null ? splatViewerPosterMaxBytes : GeneratedMediaSink.maxPostBytes;

  @override
  bool received(String name, Uint8List body) {
    final saving = this.saving;
    if (name == 'poster' && saving != null) {
      return isSplatViewerPoster(body) && saving.takePoster(body);
    }
    if (name != 'events') {
      return false;
    }
    try {
      final json = jsonDecode(utf8.decode(body));
      if (json is Map<String, Object?>) {
        final event = SplatViewerEvent.parse(json);
        if (event is SplatViewerSave || event is SplatViewerCancelSave) {
          saving?.onEvent(event!);
        } else if (event != null) {
          if (event is SplatViewerUpright) {
            saving?.upright(event.value);
          }
          onEvent(event);
        }
      }
    } on FormatException {
      // A post that is not JSON is dropped: the page goes on
    }
    return true;
  }
}
