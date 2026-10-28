// Why this file exists: "Preview in 3D" (design-final 2026-10-27, sections 2.7 and 9.1) shows a 3D scene on the
// computer that made it, so that a scene can be judged, and refused, before it is copied to the NAS for the headset.
// It opens from a photo that carries a scene: the viewer (DesktopScenePreviewButton in its top bar), the row of the
// scene in "Versions" of the original, and the line of a finished scene in the panel of the conversions.
//
// The page reads the whole photo away from the screen (its packet, its tail checked by its sum, its glb by
// glb_reader.dart), decodes its textures at 2048 pixels at most, then draws the scene with Canvas.drawVertices
// (scene_projection.dart): no shader, nothing new in the pubspec. A drag moves the eye within the zone, the wheel
// forward and back, Reset brings it back to where the photo was taken; beyond the zone the scene flattens and darkens
// as in the headset. The honesty label stays under the scene: "Reconstructed from one photo, explore within its
// limits", with "Preview: the headset shows the full detail". A photo whose scene cannot be read is shown flat with
// its reason, the words of the headset: the scene data missing, not a scene of ours, made by a newer version.
//
// Reading a scene is not an AI feature (spec 8.4): no model, no component, and the general switch of the AI features
// leaves it alone.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_reader.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_projection.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ScenePreview');

/// The longest side of a texture of the preview: the headset shows the full detail
const scenePreviewTextureMax = 2048;

/// Why a photo cannot be previewed in 3D
enum ScenePreviewProblem {
  /// The file cannot be read
  unreadable,

  /// No packet of a 3D scene at its head, or a scene that is not ours: "Not a scene made by Immuch360"
  notOurs,

  /// A packet or a scene of a later format: "Made by a newer version of Immuch360"
  newerVersion,

  /// The packet names a scene the file does not hold, or not the bytes it sums (another program saved the JPEG
  /// again): "The 3D scene data is missing from this file"
  missing,
}

class ScenePreviewException implements Exception {
  const ScenePreviewException(this.problem);

  final ScenePreviewProblem problem;

  @override
  String toString() => 'ScenePreviewException(${problem.name})';
}

/// The words of [problem]
String scenePreviewProblemText(Translations t, ScenePreviewProblem problem) => switch (problem) {
  ScenePreviewProblem.unreadable => t.scaffold_body_error_occurred,
  ScenePreviewProblem.notOurs => t.ai_immersive_scene_not_ours,
  ScenePreviewProblem.newerVersion => t.ai_immersive_newer_version,
  ScenePreviewProblem.missing => t.ai_immersive_scene_missing,
};

/// The scene of a photo, read: its packet and its glb
class ScenePreviewData {
  const ScenePreviewData({required this.xmp, required this.scene});

  final SceneXmp xmp;
  final GlbScene scene;
}

/// The scene the photo [file] (all its bytes) carries; a [ScenePreviewException] when it carries none this build reads
ScenePreviewData scenePreviewOf(Uint8List file) {
  final xmp = ImmersiveXmp.findIn(Uint8List.sublistView(file, 0, math.min(file.length, versionHeadLength)));
  if (xmp is! SceneXmp) {
    throw const ScenePreviewException(ScenePreviewProblem.notOurs);
  }
  if (xmp.isNewerFormat || (GlbReader.formatVersionOf(xmp.sceneFormat) ?? 1) > 1) {
    throw const ScenePreviewException(ScenePreviewProblem.newerVersion);
  }
  if (!xmp.isReadableScene) {
    throw const ScenePreviewException(ScenePreviewProblem.notOurs);
  }
  final glb = sceneBytesOf(file, xmp);
  if (glb == null) {
    throw const ScenePreviewException(ScenePreviewProblem.missing);
  }
  try {
    return ScenePreviewData(xmp: xmp, scene: GlbReader.read(glb));
  } on GlbException catch (error) {
    _log.info('The scene cannot be previewed: $error');
    throw ScenePreviewException(
      error.problem == GlbProblem.newerFormat ? ScenePreviewProblem.newerVersion : ScenePreviewProblem.notOurs,
    );
  }
}

/// Reads the photo at [path] and its scene in an isolate of its own: some 8 MB read, summed and parsed
Future<ScenePreviewData> readScenePreview(String path) => Isolate.run(() {
  final Uint8List file;
  try {
    file = File(path).readAsBytesSync();
  } on FileSystemException {
    throw const ScenePreviewException(ScenePreviewProblem.unreadable);
  }
  return scenePreviewOf(file);
});

/// A scene ready to draw: its geometry and its textures, decoded
class LoadedScenePreview {
  LoadedScenePreview({required this.model, required this.textures});

  final ScenePreviewModel model;
  final List<ui.Image> textures;

  void dispose() {
    for (final texture in textures) {
      texture.dispose();
    }
  }
}

/// The textures of [scene] decoded, their longest side at most [scenePreviewTextureMax]
Future<List<ui.Image>> decodeSceneTextures(GlbScene scene) async {
  final images = <ui.Image>[];
  try {
    for (final texture in scene.textures) {
      final scale = math.min(1.0, scenePreviewTextureMax / math.max(texture.width, texture.height));
      final codec = await ui.instantiateImageCodec(
        texture.bytes,
        targetWidth: scale < 1 ? math.max(1, (texture.width * scale).round()) : null,
        targetHeight: scale < 1 ? math.max(1, (texture.height * scale).round()) : null,
      );
      try {
        images.add((await codec.getNextFrame()).image);
      } finally {
        codec.dispose();
      }
    }
  } catch (error) {
    for (final image in images) {
      image.dispose();
    }
    _log.info('A texture of the scene cannot be decoded: $error');
    throw const ScenePreviewException(ScenePreviewProblem.notOurs);
  }
  return images;
}

/// Reads the scene of the photo at [path] and decodes its textures; its zone and its field of view are those of its
/// packet, which is what the headset goes by too
Future<LoadedScenePreview> loadScenePreview(String path) async {
  final data = await readScenePreview(path);
  final textures = await decodeSceneTextures(data.scene);
  return LoadedScenePreview(
    model: ScenePreviewModel(data.scene, safe: data.xmp.safe, fovDegrees: data.xmp.fieldOfView),
    textures: textures,
  );
}

/// Loads a scene for the preview; replaced in tests
final scenePreviewLoaderProvider = Provider<Future<LoadedScenePreview> Function(String path)>(
  (ref) => loadScenePreview,
);

/// Opens the preview of the photo at a path, over the window; replaced in tests
final scenePreviewOpenerProvider = Provider<void Function(BuildContext context, String path)>(
  (ref) =>
      (context, path) => unawaited(Navigator.of(context, rootNavigator: true).push(ScenePreviewPage.route(path))),
);

/// Whether a version told by its [kind], else by its [origin] (a version the scan has not read again since the index
/// learnt the kinds), is a 3D scene
bool isSceneVersion(ImmersiveKind? kind, IndexedOrigin? origin) =>
    kind == ImmersiveKind.volumetricScene || (kind == null && origin == IndexedOrigin.reconstructed);

/// Whether the photo named [name], which the index of the library knows as [version] (null for an ordinary photo, or
/// one the library does not hold), may carry a scene, so that its head is worth reading: our index says it is a scene,
/// or, for a file the index does not know, its name holds the word "scene3D" ("salon_scene3D.jpg")
bool mayCarryScene({required String name, IndexedVersion? version}) {
  if (version != null) {
    return isSceneVersion(version.kind, version.origin);
  }
  return name.toLowerCase().split(RegExp(r'[._\- ]+')).contains('scene3d');
}

/// A photo of the computer that carries a 3D scene: its file and its packet
class SceneFile {
  const SceneFile({required this.path, required this.xmp});

  final String path;
  final SceneXmp xmp;

  /// A scene of a format this build reads; one of a later format keeps its button, greyed with its reason
  bool get canPreview => xmp.isReadableScene;
}

/// The scene the photo [asset] carries, when it is a file of this computer that carries one; null for any other
/// photo, whose head is never read unless the index or its name says it may be a scene
final sceneFileOfAssetProvider = FutureProvider.autoDispose.family<SceneFile?, BaseAsset>((ref, asset) async {
  final localId = asset.localId;
  if (!asset.isImage || localId == null) {
    return null;
  }
  IndexedVersion? version;
  try {
    version = (await ref.watch(generatedVersionsProvider.future))[localId];
  } catch (error) {
    // A file opened with the program, outside the library: its name tells
    _log.fine('The index does not tell ${asset.name}: $error');
  }
  if (!mayCarryScene(name: asset.name, version: version)) {
    return null;
  }
  final file = await ref.watch(storageRepositoryProvider).getFileForAsset(localId);
  final head = file == null ? null : await readFileHead(file.path);
  final xmp = head == null ? null : ImmersiveXmp.findIn(head);
  return file != null && xmp is SceneXmp ? SceneFile(path: file.path, xmp: xmp) : null;
});

/// "Preview in 3D" in the top bar of the viewer of a computer, on a photo that carries a 3D scene; greyed with its
/// reason for a scene of a later format; nothing on any other photo
class DesktopScenePreviewButton extends ConsumerWidget {
  const DesktopScenePreviewButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scene = ref.watch(sceneFileOfAssetProvider(asset)).valueOrNull;
    if (scene == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    return IconButton(
      key: const Key('desktop_scene_preview'),
      icon: const Icon(Icons.view_in_ar_rounded),
      tooltip: scene.canPreview ? t.ai_immersive_preview_3d : t.ai_immersive_newer_version,
      onPressed: scene.canPreview ? () => ref.read(scenePreviewOpenerProvider)(context, scene.path) : null,
    );
  }
}

/// "Preview in 3D" as an icon, for the row of a scene in "Versions"
class ScenePreviewIconButton extends ConsumerWidget {
  const ScenePreviewIconButton({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: context.t.ai_immersive_preview_3d,
    icon: const Icon(Icons.view_in_ar_rounded),
    onPressed: () => ref.read(scenePreviewOpenerProvider)(context, path),
  );
}

/// See the top of this file
class ScenePreviewPage extends ConsumerStatefulWidget {
  const ScenePreviewPage({super.key, required this.path});

  final String path;

  static Route<void> route(String path) => PageRouteBuilder<void>(
    settings: const RouteSettings(name: routeName),
    pageBuilder: (context, _, _) => ScenePreviewPage(path: path),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  static const routeName = 'ScenePreview';

  @override
  ConsumerState<ScenePreviewPage> createState() => _ScenePreviewPageState();
}

class _ScenePreviewPageState extends ConsumerState<ScenePreviewPage> {
  LoadedScenePreview? _loaded;
  ScenePreviewProblem? _problem;
  SceneEye _eye = SceneEye.start;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final loaded = await ref.read(scenePreviewLoaderProvider)(widget.path);
      if (_disposed) {
        loaded.dispose();
        return;
      }
      setState(() => _loaded = loaded);
    } catch (error) {
      if (_disposed) {
        return;
      }
      _log.info('No preview of ${widget.path}: $error');
      setState(() => _problem = error is ScenePreviewException ? error.problem : ScenePreviewProblem.unreadable);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loaded?.dispose();
    super.dispose();
  }

  void _move(SceneEye eye) {
    if (eye != _eye) {
      setState(() => _eye = eye);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final loaded = _loaded;
    final problem = _problem;
    final Widget body;
    if (loaded != null) {
      final safe = loaded.model.safe;
      body = LayoutBuilder(
        builder: (context, constraints) => Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _move(SceneEyeMoves.wheel(_eye, event.scrollDelta.dy, safe));
            }
          },
          child: GestureDetector(
            onPanUpdate: (details) => _move(SceneEyeMoves.drag(_eye, details.delta, constraints.biggest, safe)),
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: ClipRect(
                child: CustomPaint(
                  key: const Key('scene_preview_canvas'),
                  size: Size.infinite,
                  painter: ScenePreviewPainter(model: loaded.model, textures: loaded.textures, eye: _eye),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (problem != null) {
      body = Stack(
        fit: StackFit.expand,
        children: [
          // The photo itself, flat, as the headset leaves it
          if (problem != ScenePreviewProblem.unreadable)
            Image.file(
              File(widget.path),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
            ),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  scenePreviewProblemText(t, problem),
                  key: const Key('scene_preview_problem'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      body = Center(
        key: const Key('scene_preview_loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t.ai_immersive_scene_preparing, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('scene_preview'),
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            leading: IconButton(
              tooltip: t.close,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Text(t.ai_immersive_preview_3d),
            actions: [
              if (loaded != null)
                TextButton.icon(
                  key: const Key('scene_preview_reset'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: _eye == SceneEye.start ? null : () => _move(SceneEye.start),
                  icon: const Icon(Icons.center_focus_strong_rounded),
                  label: Text(t.ai_immersive_scene_reset),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: body),
              Container(
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  children: [
                    Text(
                      t.ai_immersive_scene_honesty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      t.ai_immersive_preview_banner,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws a scene seen from [eye] (scene_projection.dart): black around it, the layers from the back to the front,
/// then the darkening beyond the zone
class ScenePreviewPainter extends CustomPainter {
  ScenePreviewPainter({required this.model, required this.textures, required this.eye});

  final ScenePreviewModel model;
  final List<ui.Image> textures;
  final SceneEye eye;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    canvas.drawRect(area, Paint()..color = Colors.black);
    if (size.isEmpty) {
      return;
    }
    final view = SceneView.fit(size, aspect: model.photoAspect, fovDegrees: model.fovDegrees);
    final frame = model.frame(
      view,
      eye,
      textureSizes: [for (final texture in textures) Size(texture.width.toDouble(), texture.height.toDouble())],
    );
    final paints = [
      for (final texture in textures)
        Paint()
          ..shader = ImageShader(
            texture,
            TileMode.clamp,
            TileMode.clamp,
            Float64List.fromList(const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
            filterQuality: FilterQuality.medium,
          ),
    ];
    for (final batch in frame.batches) {
      canvas.drawVertices(
        ui.Vertices.raw(
          ui.VertexMode.triangles,
          batch.positions,
          textureCoordinates: batch.textureCoordinates,
          indices: batch.indices,
        ),
        BlendMode.srcOver,
        paints[batch.texture],
      );
    }
    if (frame.darken > 0) {
      canvas.drawRect(area, Paint()..color = Color.fromRGBO(0, 0, 0, frame.darken));
    }
  }

  @override
  bool shouldRepaint(ScenePreviewPainter oldDelegate) =>
      oldDelegate.eye != eye || oldDelegate.model != model || oldDelegate.textures != textures;
}
