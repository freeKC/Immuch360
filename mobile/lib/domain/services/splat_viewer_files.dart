// What the splat viewer of the computers, phones and tablets keeps on this device (lot SV4 of the splat viewer):
//
// * the orientation the user chose for a file with Turn upright, under the headset's key splatUp:<bytes>:<name>, in
//   a small JSON file of the app (the headset keeps its own in SharedPreferences): the same file opens upright at once
//   on this device afterwards;
// * on a computer (lot SVC), the answer the user gave when the first frames of a file were slow (the reduced copy of
//   N gaussians, or every gaussian) under splatFrames:<bytes>:<name>, and the graphics chip the page last said it drew
//   with, in another small JSON file (SplatAnswerStore);
// * the reduced copies of the splats above the cap of this device: the last three, 1 GiB at most together, keyed by
//   the source (share and path, or file path), its size, its date when the file system gives one, a fingerprint of
//   its content and the cap, so that opening the same splat again skips "Preparing the splat" and another file of the
//   same name and size never shows a copy that is not its own (review of 2 November 2026); a file of a share to reduce
//   is first copied into the same folder, through the share, so that the two passes of the reduction never cross the
//   network twice, and deleted once reduced. The folder is the app's own cache folder, never the system's temporary
//   folder that every copy of the app and every user share.
//
// The reduction runs in an isolate of its own, with progress, and a cancel that ends the isolate at once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
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

/// The key of the answer for the file [name] of [fileBytes], beside the headset's key of its orientation
String splatAnswerKey(String name, int fileBytes) => 'splatFrames:$fileBytes:$name';

/// The key of the renderer the page last said it drew with, per set of the web view's arguments ([highPerformance]:
/// the dedicated chip asked on a Windows computer with two)
String splatRendererKey({required bool highPerformance}) => 'renderer:${highPerformance ? 'high' : 'default'}';

/// The answers to the page's offer per file and the renderer the page last drew with (see the top of this file), in
/// the JSON file [file] gives; read once, each change written at once
class SplatAnswerStore {
  SplatAnswerStore(this._file);

  /// The most files remembered: the oldest answers go first
  static const maxEntries = 500;

  final Future<File> Function() _file;
  Future<Map<String, Object?>>? _loading;
  Future<void> _writing = Future.value();

  Future<Map<String, Object?>> _load() => _loading ??= () async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return <String, Object?>{};
      }
      final json = jsonDecode(await file.readAsString());
      return {if (json is Map) ...json.map((key, value) => MapEntry('$key', value))};
    } catch (error) {
      _log.warning('The answers of the splat viewer could not be read: $error');
      return <String, Object?>{};
    }
  }();

  /// What the user answered for the file [name] of [fileBytes], null when nothing
  Future<SplatFrameAnswer?> answer(String name, int fileBytes) async =>
      SplatFrameAnswer.fromJson((await _load())[splatAnswerKey(name, fileBytes)]);

  /// Remembers [answer] for the file [name] of [fileBytes]
  Future<void> writeAnswer(String name, int fileBytes, SplatFrameAnswer answer) =>
      _write(splatAnswerKey(name, fileBytes), answer.toJson());

  /// The renderer the page last said it drew with, under the arguments of [highPerformance]
  Future<String?> renderer({required bool highPerformance}) async {
    final value = (await _load())[splatRendererKey(highPerformance: highPerformance)];
    return value is String ? value : null;
  }

  /// Remembers [name] as the renderer of the arguments of [highPerformance], when it changed
  Future<void> writeRenderer(String name, {required bool highPerformance}) async {
    if (await renderer(highPerformance: highPerformance) == name) {
      return;
    }
    await _write(splatRendererKey(highPerformance: highPerformance), name);
  }

  Future<void> _write(String key, Object? value) async {
    final entries = await _load();
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
        _log.warning('An answer of the splat viewer could not be written: $error');
      }
    });
    await _writing;
  }
}

/// The reduced copies of the splats (see the top of this file), in [folder]
class SplatViewerCache {
  SplatViewerCache(
    this._folder, {
    this.keep = 3,
    this.maxBytes = 1 << 30,
    this.serverKeep = 5,
    this.serverMaxBytes = 1 << 30,
  });

  final Future<Directory> Function() _folder;

  /// The most reduced copies kept, and their most bytes together
  final int keep;
  final int maxBytes;

  /// The most scenes of splat photos of the server kept (`server-<asset>-<sum>.spz`, plan of 3 November 2026, section
  /// 5.3), and their most bytes together: apart from the reduced copies, so that neither evicts the other
  final int serverKeep;
  final int serverMaxBytes;

  /// The prefix of the scenes of splat photos of the server
  static const serverPrefix = 'server-';

  /// The name of the reduced copy of [source] (a share and a path, or a path) of [fileBytes] changed at [modified],
  /// whose content gives [fingerprint] (splatFingerprint), reduced to [cap], in [format]
  static String nameOf(
    String source,
    int fileBytes,
    DateTime? modified,
    int cap,
    SplatFormat format, {
    String fingerprint = '',
  }) {
    final key = '$source|$fileBytes|${modified?.millisecondsSinceEpoch}|$cap|$fingerprint';
    return 'reduced-${sha1.convert(utf8.encode(key))}.${format.json}';
  }

  /// How old a file that is not a finished reduced copy must be before a prune deletes it: a copy from a share or a
  /// reduction of another viewing may be in progress, and a day is far longer than any
  static const leftoverAge = Duration(days: 1);

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

  /// Whether [path] is in the app's cache folder, the one this folder is in: a file the app copied there (Android
  /// copies a picked splat to cache/picked-splat at each pick) has the date of its copy, not of its content
  Future<bool> isAppCopy(String path) async => p.isWithin(p.dirname((await folder()).path), p.absolute(path));

  /// A file of the folder for [name], not made yet
  Future<File> fileFor(String name) async => File(p.join((await folder()).path, name));

  /// Keeps the [keep] newest reduced copies within [maxBytes]; the copies of shares and the unfinished files a viewing
  /// left (a crash, a power cut) go once older than [leftoverAge], those of a viewing in progress stay (each viewing
  /// deletes its own)
  Future<void> prune() async {
    final dir = await folder();
    final reduced = <(File, FileStat)>[];
    final server = <(File, FileStat)>[];
    final now = DateTime.now();
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      final stat = entity.statSync();
      if (name.startsWith('reduced-') && !name.endsWith('.part')) {
        reduced.add((entity, stat));
      } else if (name.startsWith(serverPrefix) && name.endsWith('.spz')) {
        server.add((entity, stat));
      } else if (now.difference(stat.modified) > leftoverAge) {
        await _delete(entity);
      }
    }
    await _keepNewest(reduced, keep, maxBytes);
    await _keepNewest(server, serverKeep, serverMaxBytes);
  }

  /// Keeps the [most] newest of [files] within [maxBytes] together
  static Future<void> _keepNewest(List<(File, FileStat)> files, int most, int maxBytes) async {
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var total = 0;
    for (var i = 0; i < files.length; i++) {
      total += files[i].$2.size;
      if (i >= most || total > maxBytes) {
        await _delete(files[i].$1);
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

/// The steps of the preparation of a splat: the copy of a file of a share and the reduction of a splat above the cap;
/// the download of the scene of a splat photo of the server (plan of 3 November 2026, section 5.3)
enum SplatPrepareStep { download, copy, reduce }

/// The bytes of each end of a file the fingerprint reads, the bytes it reads at each place between, and the number of
/// those places; a file up to [splatFingerprintWhole] bytes is read whole
const splatFingerprintEdge = 64 << 10;
const splatFingerprintSample = 8 << 10;
const splatFingerprintPlaces = 7;
const splatFingerprintWhole = 1 << 20;

/// What tells one version of a splat file from another of the same name and size (review of 2 November 2026): a
/// SHA-1 of its first and last 64 KiB and of 8 KiB at seven places between, read through [read] from a file of
/// [length] bytes (about 184 KiB, a few reads of a share). Every gaussian of a file trained or exported again moves,
/// and a PLY's rows start within its first kilobytes, so two scenes never give the same one in practice; the date of
/// the file, where the file system gives one, joins it in the key of the reduced copy for the edits of a few rows.
Future<String> splatFingerprint(Future<List<int>> Function(int offset, int length) read, int length) async {
  final ranges = <(int, int)>[];
  if (length <= splatFingerprintWhole) {
    ranges.add((0, length));
  } else {
    ranges.add((0, splatFingerprintEdge));
    for (var place = 1; place <= splatFingerprintPlaces; place++) {
      ranges.add((length * place ~/ (splatFingerprintPlaces + 1), splatFingerprintSample));
    }
    ranges.add((length - splatFingerprintEdge, splatFingerprintEdge));
  }
  final bytes = BytesBuilder(copy: false);
  for (final (offset, count) in ranges) {
    if (count > 0) {
      final part = await read(offset, count);
      if (part.length != count) {
        throw SplatReduceException('the file gave ${part.length} bytes of $count at $offset');
      }
      bytes.add(part);
    }
  }
  return '${sha1.convert(bytes.takeBytes())}';
}

/// The free space a preparation needs, in bytes: the copy of a file of a share ([copied], [fileBytes]) and the reduced
/// file at most (a PLY's rows in proportion; an SPZ written again as version 2, uncompressed at most: 19 bytes a
/// gaussian and 3 for each harmonic coefficient of each colour), and 1 MiB
int splatPrepareBytes(SplatHead head, {required int fileBytes, required int cap, required bool copied}) {
  final kept = math.min(cap, head.gaussians);
  final int reduced;
  if (head.format == SplatFormat.ply) {
    reduced = head.gaussians <= 0 ? fileBytes : (fileBytes * kept / head.gaussians).ceil();
  } else {
    final coefficients = (head.shDegree + 1) * (head.shDegree + 1) - 1;
    reduced = 16 + kept * (19 + 3 * coefficients);
  }
  return (copied ? fileBytes : 0) + reduced + (1 << 20);
}

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
