// The tiles of the network share browser: a photo with its thumbnail, a video with a placeholder (a frame of the video
// is for later), a 360° badge on the files that declare a 360° projection, and the folder rows.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';

/// Width the photo thumbnails of the browser are decoded at
const networkThumbnailWidth = 400;

/// Photos larger than this many bytes get no thumbnail: the media bridge streams the whole file for one
const networkThumbnailMaxFileSize = 30 * 1024 * 1024;

/// The thumbnail of a photo of a share at [url] on the media bridge, see [NetworkThumbnailImage]. Tests replace it.
final networkThumbnailImageProvider = Provider<ImageProvider Function(Uri url)>((_) => NetworkThumbnailImage.new);

/// The thumbnail of a photo of a share: the whole file through the media bridge at [url], decoded at most [width]
/// pixels wide, like a ResizeImage of a NetworkImage. A few photos load at a time, so that a folder of large
/// panoramas does not hold many whole files in memory at once.
class NetworkThumbnailImage extends ImageProvider<NetworkThumbnailImage> {
  const NetworkThumbnailImage(this.url, {this.width = networkThumbnailWidth});

  final Uri url;
  final int width;

  /// Most photos loaded and decoded at once
  static const maxConcurrent = 3;

  static int _loading = 0;
  static final _waiting = Queue<Completer<void>>();
  static HttpClient? _client;

  @override
  Future<NetworkThumbnailImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkThumbnailImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: url.path);

  Future<ui.Codec> _load(NetworkThumbnailImage key, ImageDecoderCallback decode) async {
    await _takeTurn();
    try {
      final client = _client ??= HttpClient()..autoUncompress = false;
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: url);
      }
      final bytes = await consolidateHttpClientResponseBytes(response);
      if (bytes.isEmpty) {
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: url);
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(
        buffer,
        getTargetSize: (intrinsicWidth, _) =>
            intrinsicWidth > width ? ui.TargetImageSize(width: width) : const ui.TargetImageSize(),
      );
    } catch (_) {
      // Loaded again the next time it is shown
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      _endTurn();
    }
  }

  static Future<void> _takeTurn() async {
    if (_loading < maxConcurrent) {
      _loading++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    // Handed over by _endTurn, the count of loads under way staying the same
    await turn.future;
  }

  static void _endTurn() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _loading--;
    }
  }

  @override
  bool operator ==(Object other) => other is NetworkThumbnailImage && other.url == url && other.width == width;

  @override
  int get hashCode => Object.hash(url, width);

  @override
  String toString() => 'NetworkThumbnailImage($url, width: $width)';
}

/// Keeps the last [maxEntries] photo thumbnails of the browser decoded in memory, whatever else the image cache of
/// the app holds meanwhile, so that scrolling back to them does not stream their files from the share again.
///
/// A thumbnail stays known to the image cache as long as something listens to it: the cache listens to the ones it
/// keeps, until they are dropped.
class NetworkThumbnailCache {
  NetworkThumbnailCache({this.maxEntries = 120});

  final int maxEntries;

  // The least recently shown first
  final _kept = <ImageProvider, (ImageStream, ImageStreamListener)>{};

  /// Keeps [image], already loaded, in memory; it goes last, as the most recently shown
  void retain(ImageProvider image) {
    final kept = _kept.remove(image);
    if (kept != null) {
      _kept[image] = kept;
      return;
    }
    // Loaded already: the image cache gives it back right away
    final stream = image.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose(), onError: (_, _) {});
    stream.addListener(listener);
    _kept[image] = (stream, listener);
    while (_kept.length > maxEntries) {
      _release(_kept.remove(_kept.keys.first));
    }
  }

  /// How many thumbnails are kept
  int get length => _kept.length;

  void clear() {
    final kept = _kept.values.toList();
    _kept.clear();
    kept.forEach(_release);
  }

  static void _release((ImageStream, ImageStreamListener)? kept) {
    if (kept != null) {
      kept.$1.removeListener(kept.$2);
    }
  }
}

final networkThumbnailCacheProvider = Provider<NetworkThumbnailCache>((ref) {
  final cache = NetworkThumbnailCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// What the file of a photo or video of a share declares (see [NetworkMediaService.detect]), for the 360° badge of
/// the browser: read on its share, in turn with the other tiles, and not at all once the tile is gone. Null for any
/// other file and while it could not be read.
final networkMediaInfoProvider = FutureProvider.autoDispose.family<NetworkMediaInfo?, NetworkMediaKey>((
  ref,
  key,
) async {
  var wanted = true;
  ref.onDispose(() => wanted = false);
  final entry = NetworkEntry(
    sourceId: key.sourceId,
    path: key.path,
    isDirectory: false,
    size: key.size,
    modified: key.modified,
  );
  if (!entry.isMedia) {
    return null;
  }
  final service = ref.read(networkMediaServiceProvider);
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(key.sourceId);
  return service.detect(entry, networkFileReader(fileSystem, key.path), isWanted: () => wanted);
});

/// A photo or a video of a share in the grid of the browser. [url] is its media bridge URL, null when there is none.
class NetworkMediaTile extends ConsumerWidget {
  const NetworkMediaTile({super.key, required this.entry, required this.url, required this.onTap});

  final NetworkEntry entry;
  final Uri? url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final is360 = ref.watch(
      networkMediaInfoProvider(networkMediaKey(entry)).select((info) => info.valueOrNull?.is360 ?? false),
    );
    final url = this.url;
    final hasThumbnail = entry.isImage && url != null && (entry.size ?? 0) <= networkThumbnailMaxFileSize;

    return Semantics(
      label: entry.name,
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: context.colorScheme.surfaceContainerHighest),
              if (hasThumbnail)
                _PhotoThumbnail(url: url, name: entry.name)
              else
                _Placeholder(icon: entry.isVideo ? Icons.movie_outlined : Icons.image_outlined, name: entry.name),
              if (entry.isVideo)
                const Positioned(
                  left: 6,
                  bottom: 6,
                  child: Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 20, shadows: _shadows),
                ),
              if (is360)
                const Positioned(
                  key: Key('network_media_360_badge'),
                  right: 6,
                  top: 6,
                  child: Icon(Icons.threesixty_rounded, color: Colors.white, size: 18, shadows: _shadows),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

const _shadows = [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6))];

class _PhotoThumbnail extends ConsumerWidget {
  const _PhotoThumbnail({required this.url, required this.name});

  final Uri url;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(networkThumbnailImageProvider)(url);
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, _) {
        if (frame != null) {
          ref.read(networkThumbnailCacheProvider).retain(image);
        }
        return child;
      },
      errorBuilder: (context, _, _) => _Placeholder(icon: Icons.broken_image_outlined, name: name),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.name});

  final IconData icon;
  final String name;

  @override
  Widget build(BuildContext context) {
    final color = context.colorScheme.onSurface.withAlpha(150);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A folder of a share in the browser
class NetworkFolderTile extends StatelessWidget {
  const NetworkFolderTile({super.key, required this.entry, required this.onTap});

  final NetworkEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 12),
      leading: Icon(Icons.folder_outlined, color: context.primaryColor),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
