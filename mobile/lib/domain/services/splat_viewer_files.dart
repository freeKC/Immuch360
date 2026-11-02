// What the splat viewer of the computers, phones and tablets keeps on this device (lot SV4 of the splat viewer):
//
// * the orientation the user chose for a file with Turn upright, under the headset's key splatUp:<bytes>:<name>, in
//   a small JSON file of the app (the headset keeps its own in SharedPreferences): the same file opens upright at once
//   on this device afterwards;
// * the reduced copies of the splats above the cap of this device: the last three, 1 GiB at most together, keyed by
//   the source (share and path, or file path), its size and date and the cap, so that opening the same splat again
//   skips "Preparing the splat"; a file of a share to reduce is first copied into the same folder, through the share,
//   so that the two passes of the reduction never cross the network twice, and deleted once reduced.
//
// The reduction runs in an isolate of its own, with progress, and a cancel that ends the isolate at once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SplatViewerFiles');

/// The orientations of Turn upright the page sends and takes
const splatUprightValues = {'yUp', 'zUp', 'yDown'};

/// The key the headset keeps the orientation of a file under (SplatUprightMemory.kt)
String splatUprightKey(String name, int fileBytes) => 'splatUp:$fileBytes:$name';

/// The orientations chosen with Turn upright, in the JSON file [file] gives; read once, each change written at once
class SplatUprightStore {
  SplatUprightStore(this._file);

  /// The most files remembered: the oldest choices go first
  static const maxEntries = 500;

  final Future<File> Function() _file;
  Future<Map<String, String>>? _loading;
  Future<void> _writing = Future.value();

  Future<Map<String, String>> _load() => _loading ??= () async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return <String, String>{};
      }
      final json = jsonDecode(await file.readAsString());
      return {
        if (json is Map)
          for (final entry in json.entries)
            if (entry.key is String && splatUprightValues.contains(entry.value))
              entry.key as String: entry.value as String,
      };
    } catch (error) {
      _log.warning('The orientations of the splats could not be read: $error');
      return <String, String>{};
    }
  }();

  /// The orientation the user chose for the file [name] of [fileBytes], null when none
  Future<String?> read(String name, int fileBytes) async => (await _load())[splatUprightKey(name, fileBytes)];

  /// Remembers [value] for the file [name] of [fileBytes]
  Future<void> write(String name, int fileBytes, String value) async {
    if (!splatUprightValues.contains(value)) {
      return;
    }
    final entries = await _load();
    final key = splatUprightKey(name, fileBytes);
    entries.remove(key);
    entries[key] = value;
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    final text = jsonEncode(entries);
    _writing = _writing.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        await file.writeAsString(text, flush: true);
      } catch (error) {
        _log.warning('The orientation of a splat could not be written: $error');
      }
    });
    await _writing;
  }
}

/// The reduced copies of the splats (see the top of this file), in [folder]
class SplatViewerCache {
  SplatViewerCache(this._folder, {this.keep = 3, this.maxBytes = 1 << 30});

  final Future<Directory> Function() _folder;

  /// The most reduced copies kept, and their most bytes together
  final int keep;
  final int maxBytes;

  /// The name of the reduced copy of [source] (a share and a path, or a path) of [fileBytes] changed at [modified],
  /// reduced to [cap], in [format]
  static String nameOf(String source, int fileBytes, DateTime? modified, int cap, SplatFormat format) {
    final key = '$source|$fileBytes|${modified?.millisecondsSinceEpoch}|$cap';
    return 'reduced-${sha1.convert(utf8.encode(key))}.${format.json}';
  }

  Future<Directory> folder() async {
    final folder = await _folder();
    await folder.create(recursive: true);
    return folder;
  }

  /// The reduced copy named [name] when it is there, its date moved to now so that it is the last one dropped
  Future<File?> find(String name) async {
    final file = File(p.join((await folder()).path, name));
    if (!file.existsSync()) {
      return null;
    }
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException {
      // Kept as it is
    }
    return file;
  }

  /// A file of the folder for [name], not made yet
  Future<File> fileFor(String name) async => File(p.join((await folder()).path, name));

  /// Keeps the [keep] newest reduced copies within [maxBytes]; the copies of shares and the unfinished files go
  Future<void> prune() async {
    final dir = await folder();
    final reduced = <(File, FileStat)>[];
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('reduced-') && !name.endsWith('.part')) {
        reduced.add((entity, entity.statSync()));
      } else {
        await _delete(entity);
      }
    }
    reduced.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var total = 0;
    for (var i = 0; i < reduced.length; i++) {
      total += reduced[i].$2.size;
      if (i >= keep || total > maxBytes) {
        await _delete(reduced[i].$1);
      }
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already, or held: the next prune tries again
    }
  }
}

/// The steps of the preparation of a splat above the cap
enum SplatPrepareStep { copy, reduce }

/// Cancels a preparation: [cancel] stops it at once
class SplatPrepareCancel {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

/// Reduces [source] (its head [head]) to [keep] gaussians into [out] in an isolate of its own; [progress] is told the
/// share done. A [cancel] ends the isolate and deletes [out], then throws [SplatReduceCancelled].
Future<int> reduceSplatInIsolate({
  required File source,
  required SplatHead head,
  required int keep,
  required File out,
  void Function(double done)? progress,
  SplatPrepareCancel? cancel,
}) async {
  final part = File('${out.path}.part');
  final port = ReceivePort();
  final exit = ReceivePort();
  final errors = ReceivePort();
  final done = Completer<int>();
  port.listen((message) {
    if (message is double) {
      progress?.call(message);
    } else if (message is int && !done.isCompleted) {
      done.complete(message);
    } else if (message is List && !done.isCompleted) {
      done.completeError(SplatReduceException('${message.first}'));
    }
  });
  errors.listen((message) {
    if (!done.isCompleted) {
      done.completeError(SplatReduceException('$message'));
    }
  });
  exit.listen((_) {
    if (!done.isCompleted) {
      done.completeError(const SplatReduceException('the reduction stopped'));
    }
  });
  final isolate = await Isolate.spawn(
    _reduceMain,
    (port.sendPort, source.path, head, keep, part.path),
    onExit: exit.sendPort,
    onError: errors.sendPort,
  );
  unawaited(
    cancel?.whenCancelled.then((_) {
      isolate.kill(priority: Isolate.immediate);
      if (!done.isCompleted) {
        done.completeError(const SplatReduceCancelled());
      }
    }),
  );
  try {
    final kept = await done.future;
    await part.rename(out.path);
    return kept;
  } catch (_) {
    try {
      await part.delete();
    } on FileSystemException {
      // Never written
    }
    rethrow;
  } finally {
    port.close();
    exit.close();
    errors.close();
  }
}

Future<void> _reduceMain((SendPort, String, SplatHead, int, String) job) async {
  final (port, source, head, keep, out) = job;
  var last = -1.0;
  try {
    final kept = await reduceSplatFile(
      source: File(source),
      head: head,
      keep: keep,
      out: File(out),
      progress: (share) {
        // About a hundred messages for the whole file
        if (share - last >= 0.01 || share >= 1) {
          last = share;
          port.send(share);
        }
      },
    );
    port.send(kept);
  } on SplatReduceException catch (error) {
    port.send([error.detail]);
  } catch (error) {
    port.send(['$error']);
  }
}

/// Copies [length] bytes of a file read by [readRange] (a share) into [out] in chunks, [progress] told the share done;
/// a [cancel] stops it between chunks and deletes [out]
Future<void> copySplatFromShare({
  required Future<List<int>> Function(int offset, int length) readRange,
  required int length,
  required File out,
  void Function(double done)? progress,
  SplatPrepareCancel? cancel,
  int chunk = 4 << 20,
}) async {
  final sink = out.openWrite();
  try {
    for (var offset = 0; offset < length; offset += chunk) {
      if (cancel?.isCancelled ?? false) {
        throw const SplatReduceCancelled();
      }
      final want = math.min(chunk, length - offset);
      final bytes = await readRange(offset, want);
      if (bytes.length != want) {
        throw SplatReduceException('the share gave ${bytes.length} bytes of $want at $offset');
      }
      sink.add(bytes);
      progress?.call((offset + want) / length);
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close();
    try {
      await out.delete();
    } on FileSystemException {
      // Never written
    }
    rethrow;
  }
}
