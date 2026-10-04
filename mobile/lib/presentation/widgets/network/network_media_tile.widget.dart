// The tiles of the network share browser: a photo with its thumbnail, a video with a frame of it, a 360° badge on the
// files that declare a 360° projection, a badge on the files sent to the server before, the selection mark and the
// progress of an upload, and the folder rows.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/video_thumbnail_disk_cache.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  static final _idle = <Completer<void>>[];
  static HttpClient? _client;

  /// Completes once no photo thumbnail is loading nor waiting to, counting those asked for by the frame under way:
  /// the video thumbnails come after the photos on screen
  static Future<void> whenIdle() async {
    // The tiles built in the same frame resolve their photos before this goes on
    await Future<void>.delayed(Duration.zero);
    while (_loading > 0) {
      final idle = Completer<void>();
      _idle.add(idle);
      await idle.future;
    }
  }

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
      return;
    }
    _loading--;
    if (_loading == 0 && _idle.isNotEmpty) {
      final idle = _idle.toList();
      _idle.clear();
      for (final waiter in idle) {
        waiter.complete();
      }
    }
  }

  @override
  bool operator ==(Object other) => other is NetworkThumbnailImage && other.url == url && other.width == width;

  @override
  int get hashCode => Object.hash(url, width);

  @override
  String toString() => 'NetworkThumbnailImage($url, width: $width)';
}

/// The thumbnail of a video of a share, [bytes] being the JPEG frame [NetworkVideoThumbnailService] gave. Known to the
/// image cache by the video alone ([key]), so that a tile shown again finds it there without its bytes, see
/// [NetworkVideoThumbnailImage.isInMemory].
class NetworkVideoThumbnailImage extends ImageProvider<NetworkVideoThumbnailImage> {
  const NetworkVideoThumbnailImage(this.key, {this.bytes});

  final NetworkMediaKey key;
  final Uint8List? bytes;

  /// Whether the thumbnail of the video [key] is in the image cache, loaded or loading
  static bool isInMemory(NetworkMediaKey key) =>
      PaintingBinding.instance.imageCache.statusForKey(NetworkVideoThumbnailImage(key)).tracked;

  @override
  Future<NetworkVideoThumbnailImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkVideoThumbnailImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: key.key.path);

  Future<ui.Codec> _load(NetworkVideoThumbnailImage key, ImageDecoderCallback decode) async {
    try {
      final bytes = key.bytes;
      if (bytes == null || bytes.isEmpty) {
        // Dropped from the image cache between the look and the load: the tile asks again
        throw StateError('No thumbnail bytes for ${key.key.path}');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(
        buffer,
        getTargetSize: (intrinsicWidth, _) => intrinsicWidth > NetworkVideoThumbnailService.maxWidth
            ? const ui.TargetImageSize(width: NetworkVideoThumbnailService.maxWidth)
            : const ui.TargetImageSize(),
      );
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is NetworkVideoThumbnailImage && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'NetworkVideoThumbnailImage(${key.path})';
}

/// Where the video thumbnails are kept on disk, under the cache folder of the app (the system may empty it)
Future<Directory> networkVideoThumbnailDirectory() async =>
    Directory(p.join((await getApplicationCacheDirectory()).path, 'network_video_thumbnails'));

final networkVideoThumbnailServiceProvider = Provider<NetworkVideoThumbnailService>(
  (_) => NetworkVideoThumbnailService(
    api: VideoThumbnailApi(),
    diskCache: VideoThumbnailDiskCache(networkVideoThumbnailDirectory),
    waitForPhotos: NetworkThumbnailImage.whenIdle,
  ),
);

/// The JPEG thumbnail of a video of a share served by the media bridge at [NetworkVideoThumbnailRequest.url], null
/// while there is none. Not taken at all once the tile is gone before its turn.
final networkVideoThumbnailProvider = FutureProvider.autoDispose.family<Uint8List?, NetworkVideoThumbnailRequest>((
  ref,
  request,
) {
  var wanted = true;
  ref.onDispose(() => wanted = false);
  return ref.read(networkVideoThumbnailServiceProvider).thumbnail(request.key, request.url, isWanted: () => wanted);
});

typedef NetworkVideoThumbnailRequest = ({NetworkMediaKey key, Uri url});

/// Keeps the last [maxEntries] photo and video thumbnails of the browser decoded in memory, whatever else the image
/// cache of the app holds meanwhile, so that scrolling back to them does not read their files from the share again.
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
  const NetworkMediaTile({
    super.key,
    required this.entry,
    required this.url,
    required this.onTap,
    this.onLongPress,
    this.isSelected,
  });

  final NetworkEntry entry;
  final Uri? url;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Whether the file is picked, null when the browser is not picking files
  final bool? isSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final is360 = ref.watch(
      networkMediaInfoProvider(networkMediaKey(entry)).select((info) => info.valueOrNull?.is360 ?? false),
    );
    final wasSent = ref.watch(
      networkUploadRecordsProvider.select((records) => records.containsKey(UploadRecordStore.keyOf(entry))),
    );
    final uploadProgress = ref.watch(networkUploadProvider.select((upload) => upload.progress[networkUploadId(entry)]));
    final url = this.url;
    final hasThumbnail = entry.isImage && url != null && (entry.size ?? 0) <= networkThumbnailMaxFileSize;
    final hasFrame = entry.isVideo && url != null;
    final isSelected = this.isSelected;

    return Semantics(
      label: wasSent ? '${entry.name}, ${context.t.network_upload_sent_before}' : entry.name,
      button: true,
      selected: isSelected ?? false,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: context.colorScheme.surfaceContainerHighest),
              if (hasThumbnail)
                _PhotoThumbnail(url: url, name: entry.name)
              else if (hasFrame)
                _VideoThumbnail(entry: entry, url: url)
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
              if (wasSent)
                Positioned(
                  key: const Key('network_media_sent_badge'),
                  right: 6,
                  bottom: 6,
                  child: Tooltip(
                    message: context.t.network_upload_sent_before,
                    child: const Icon(Icons.cloud_done_outlined, color: Colors.white, size: 18, shadows: _shadows),
                  ),
                ),
              if (uploadProgress != null)
                Positioned.fill(child: NetworkUploadProgressOverlay(progress: uploadProgress)),
              if (isSelected != null) _SelectionMark(isSelected: isSelected),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark of a tile while the browser is picking files: a check on a tinted tile once picked, an empty circle before
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: isSelected ? context.primaryColor.withValues(alpha: 0.3) : Colors.transparent,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: isSelected
                ? DecoratedBox(
                    key: const Key('network_media_selected'),
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                    child: Icon(Icons.check_circle_rounded, color: context.primaryColor, size: 22),
                  )
                : const Icon(
                    Icons.radio_button_unchecked_rounded,
                    key: Key('network_media_unselected'),
                    color: Colors.white,
                    size: 22,
                    shadows: _shadows,
                  ),
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

/// A frame of the video, the placeholder until it comes and when there is none
class _VideoThumbnail extends ConsumerWidget {
  const _VideoThumbnail({required this.entry, required this.url});

  final NetworkEntry entry;
  final Uri url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = networkMediaKey(entry);
    final placeholder = _Placeholder(icon: Icons.movie_outlined, name: entry.name);
    // Shown before: decoded in memory still, no need for its bytes
    if (NetworkVideoThumbnailImage.isInMemory(key)) {
      return _image(ref, NetworkVideoThumbnailImage(key), placeholder);
    }
    final bytes = ref.watch(networkVideoThumbnailProvider((key: key, url: url))).valueOrNull;
    if (bytes == null) {
      return placeholder;
    }
    return _image(ref, NetworkVideoThumbnailImage(key, bytes: bytes), placeholder);
  }

  Widget _image(WidgetRef ref, NetworkVideoThumbnailImage image, Widget placeholder) {
    return Image(
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, _) {
        if (frame == null) {
          return placeholder;
        }
        ref.read(networkThumbnailCacheProvider).retain(image);
        return child;
      },
      errorBuilder: (context, _, _) => placeholder,
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
