// video_encoders.json in the support folder: the encoders that stopped during a 3D video at a frame size on this
// computer although their test passed (FreeKC's PC, 23 Nov 2026: the hardware H.264 encoder at 3072 x 3072). The jobs
// skip them at that size and the dialog says so; a stop is forgotten after [videoEncoderMemoryDays] days (a new driver
// or a new FFmpeg may mend it).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart' show VideoEncoder;
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('VideoEncoderMemory');

/// How long a stop is remembered
const videoEncoderMemoryDays = 30;

class FileVideoEncoderMemory implements VideoEncoderMemory {
  FileVideoEncoderMemory({Future<Directory> Function()? directory, DateTime Function()? now})
    : _directory = directory ?? getApplicationSupportDirectory,
      _now = now ?? DateTime.now;

  static final instance = FileVideoEncoderMemory();
  static const fileName = 'video_encoders.json';

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  Future<void> _turn = Future.value();

  @override
  Future<Set<VideoEncoder>> stoppedAt(int width, int height) async {
    final entries = await _inTurn(_read);
    return {
      for (final entry in entries)
        if (entry.width == width && entry.height == height) entry.encoder,
    };
  }

  @override
  Future<void> remember(VideoEncoder encoder, int width, int height, String said) => _inTurn(() async {
    final entries = await _read()
      ..removeWhere((entry) => entry.encoder == encoder && entry.width == width && entry.height == height);
    entries.add((encoder: encoder, width: width, height: height, at: _now().toUtc(), said: said));
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'stopped': [
          for (final entry in entries)
            {
              'encoder': entry.encoder.name,
              'width': entry.width,
              'height': entry.height,
              'at': entry.at.toIso8601String(),
              'said': entry.said.length > 600 ? entry.said.substring(entry.said.length - 600) : entry.said,
            },
        ],
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  });

  Future<File> _file() async => File(p.join((await _directory()).path, fileName));

  Future<List<({VideoEncoder encoder, int width, int height, DateTime at, String said})>> _read() async {
    final entries = <({VideoEncoder encoder, int width, int height, DateTime at, String said})>[];
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return entries;
      }
      final decoded = jsonDecode(await file.readAsString());
      final list = decoded is Map ? decoded['stopped'] : null;
      final oldest = _now().toUtc().subtract(const Duration(days: videoEncoderMemoryDays));
      for (final entry in list is List ? list : const []) {
        if (entry is! Map) {
          continue;
        }
        final encoder = VideoEncoder.values.asNameMap()[entry['encoder']];
        final width = entry['width'];
        final height = entry['height'];
        final at = DateTime.tryParse('${entry['at']}');
        if (encoder == null || width is! int || height is! int || at == null || at.isBefore(oldest)) {
          continue;
        }
        entries.add((encoder: encoder, width: width, height: height, at: at, said: '${entry['said'] ?? ''}'));
      }
    } on FileSystemException catch (error) {
      _log.warning('$fileName cannot be read: ${error.message}');
    } on FormatException catch (error) {
      _log.warning('$fileName cannot be read: $error');
    }
    return entries;
  }

  Future<T> _inTurn<T>(Future<T> Function() work) {
    final result = _turn.then((_) => work());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
