// The logs a 360° panorama that failed leaves in the logs folder of the app (release 44). The programs of a job write
// into <work>/logs/ (sd-cli.log, sdcpp_runner.dart, each run after a line of its own), and the work folder goes at the
// end of every job: after a failure that is not a cancel, PanoramaEngine first copies them into one file of the logs
// folder of the app, which "Save logs to a file" takes with the log (latestProgramLogs of save_to_folder.dart):
// `panorama-<job>-<date and time>.log`, a header (what failed and where), then the last 256 KiB of each log, the five
// newest of those files kept. Kept on failure only: "Save logs to a file" takes the ten newest logs of that folder, and
// a file per panorama made would push the logs of the splat scenes out. The splat scenes keep theirs the same way
// (keepSplatFailureLogs of splat_work_folder.dart, typed on their own work folder): a helper of its own here, so that
// the two stay apart until a shared one is worth it.

import 'dart:io';

import 'package:path/path.dart' as p;

/// How many logs of failed panoramas the logs folder of the app keeps, the newest ([keepPanoramaFailureLogs])
const panoramaFailureLogsKept = 5;

/// The most of the end of each log of a program that the log of a failure takes
const panoramaFailureLogTail = 256 * 1024;

/// `panorama-<job>-<yyyy-mm-ddThh-mm-ss>.log`, the date and time in the second group
final _failureLogName = RegExp(r'^panorama-.+-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})\.log$');

final _unsafe = RegExp('[^A-Za-z0-9_-]');

/// The name of the log of a failure of the job [jobId] at [at]: `panorama-<job>-<yyyy-mm-ddThh-mm-ss>.log`, without the
/// colons Windows refuses, any character of the job id other than a letter, a digit, - or _ made _
String panoramaFailureLogName(String jobId, DateTime at) {
  String two(int value) => '$value'.padLeft(2, '0');
  final date = '${at.year}-${two(at.month)}-${two(at.day)}T${two(at.hour)}-${two(at.minute)}-${two(at.second)}';
  return 'panorama-${jobId.replaceAll(_unsafe, '_')}-$date.log';
}

/// Where the programs of the job of the work folder [work] write their logs
Directory panoramaProgramLogs(Directory work) => Directory(p.join(work.path, 'logs'));

/// After a failure of the job [jobId] (a cancel is none): the logs its programs wrote into the work folder [work] (in
/// the order they were written, the last [tail] bytes of each that is longer) copied into [into], the logs folder of
/// the app, as one file after [header], named by [panoramaFailureLogName] at [now]; then the oldest of those files
/// beyond [keep] deleted, by the date in their names, the other files of the folder (the logs of the splat scenes) left
/// alone. The file written; null when the job wrote no log or the file could not be written (the failure is told all
/// the same).
Future<File?> keepPanoramaFailureLogs(
  Directory work,
  Directory into, {
  required String jobId,
  required String header,
  DateTime? now,
  int keep = panoramaFailureLogsKept,
  int tail = panoramaFailureLogTail,
}) async {
  final List<(File, DateTime)> logs;
  try {
    final programs = panoramaProgramLogs(work);
    if (!programs.existsSync()) {
      return null;
    }
    logs = [
      for (final entry in programs.listSync())
        if (entry is File && p.extension(entry.path) == '.log') (entry, entry.lastModifiedSync()),
    ];
  } on FileSystemException {
    return null;
  }
  if (logs.isEmpty) {
    return null;
  }
  logs.sort((a, b) {
    final byTime = a.$2.compareTo(b.$2);
    return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
  });
  final file = File(p.join(into.path, panoramaFailureLogName(jobId, now ?? DateTime.now())));
  try {
    into.createSync(recursive: true);
    final sink = file.openWrite();
    try {
      sink.write('$header\nWork folder: ${work.path}\n');
      for (final (log, _) in logs) {
        final length = log.lengthSync();
        final from = length > tail ? length - tail : 0;
        sink.write('\n===== ${p.basename(log.path)}, $length bytes${from > 0 ? ', the last $tail' : ''} =====\n');
        await sink.addStream(log.openRead(from));
      }
    } finally {
      await sink.close();
    }
  } on FileSystemException {
    return null;
  }
  _keepNewest(into, keep: keep, written: file);
  return file;
}

/// Deletes the logs of failed panoramas of [into] beyond the [keep] newest, by the date in their names and then by the
/// time they were written; [written] is never deleted
void _keepNewest(Directory into, {required int keep, required File written}) {
  try {
    final kept = <(File, String, DateTime)>[];
    for (final entry in into.listSync()) {
      final named = _failureLogName.firstMatch(p.basename(entry.path));
      if (entry is File && named != null) {
        kept.add((entry, named.group(1)!, entry.lastModifiedSync()));
      }
    }
    kept.sort((a, b) {
      final byName = b.$2.compareTo(a.$2);
      return byName != 0 ? byName : b.$3.compareTo(a.$3);
    });
    for (final (old, _, _) in kept.skip(keep)) {
      if (old.path != written.path) {
        old.deleteSync();
      }
    }
  } on FileSystemException {
    // The next failure tries again
  }
}
