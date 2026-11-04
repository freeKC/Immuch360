// What the app lets go of the graphics card before a job of the AI features on it (issue #13; note
// ai-gpu-budget-2026-11-04/measure.md, section 4.1). The budget the driver gives a job counts the memory the app itself
// holds as used: on an RTX 2060 of 8 GB under Linux, with a photo open, the app held 1.4 GiB and a panorama waited for
// ever. Before it asks the card (gpu_budget.dart), the queue lets go of:
//  - the players of videos that do not play (PlayerPool.releaseForGraphicsJob): the idle ones and those of the pages
//    and live views that are paused, each with its decoder surfaces and its texture; the video that plays stays, and
//    so does the 360° page on screen, paused or not, their share named in the message when the job has to wait;
//  - the pictures decoded in the image cache (a 360° photo is up to 128 MB as a texture): ImageCache.clear() drops its
//    entries, and those no widget shows go with them. The pictures on screen stay, held by their widgets: the cache's
//    list of live images is left as it is, since clearing it frees nothing (Flutter 3.47.2, ImageCache.clearLiveImages)
//    and would only make each of them decode again while its old copy is still held.
// The memory a player let go comes back to the card within seconds (an 8K decoder still held 1.3 GB 6 s after its
// dispose on Windows): when players were closed, the queue asks the card again a few times before it decides; pictures
// alone are no reason to wait. Nothing of the AI models is on the card between two jobs: ONNX Runtime runs on the
// processor, and sd-cli is a program of its own for each run.

import 'package:flutter/painting.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:logging/logging.dart';

final _log = Logger('GraphicsRelease');

/// What the app let go of before a job on the graphics card: the video players disposed, and the bytes of the
/// pictures dropped from the image cache (those also on screen among them stay in memory, held by their widgets)
class GraphicsRelease {
  const GraphicsRelease({this.players = 0, this.pictureBytes = 0});

  static const nothing = GraphicsRelease();

  final int players;
  final int pictureBytes;

  /// Whether the queue asks the card again while what was let go comes back (ConversionTools.gpuSettle): only once
  /// players were disposed, whose decoders give the card back late
  bool get settles => players > 0;

  @override
  String toString() => '$players video players closed, $pictureBytes bytes of pictures dropped';
}

/// Lets go of the players of [pool] that do not play and of the pictures of [images] (see the top of this file)
Future<GraphicsRelease> releaseAppGraphics({PlayerPool? pool, ImageCache? images}) async {
  var players = 0;
  if (pool != null) {
    try {
      players = await pool.releaseForGraphicsJob();
    } catch (error, stack) {
      _log.warning('The video players could not be let go', error, stack);
    }
  }
  var pictureBytes = 0;
  if (images != null) {
    pictureBytes = images.currentSizeBytes;
    images.clear();
  }
  return GraphicsRelease(players: players, pictureBytes: pictureBytes);
}

/// [releaseAppGraphics] on the app's pool, when one was made, and on the image cache of the app
Future<GraphicsRelease> releaseDesktopGraphics() =>
    releaseAppGraphics(pool: desktopPlayerPoolIfMade, images: PaintingBinding.instance.imageCache);
