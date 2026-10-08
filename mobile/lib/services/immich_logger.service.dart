import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/files/save_to_folder.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// [ImmichLogger] is a custom logger that is built on top of the [logging] package.
/// The logs are written to the database and onto console, using `debugPrint` method.
///
/// The logs are deleted when exceeding the `maxLogEntries` (default 500) property
/// in the class.
///
/// Logs can be shared by calling the `shareLogs` method, which will open a share dialog
/// and generate a csv file.
abstract final class ImmichLogger {
  /// [toFile]: on a computer, keep the logs as a file the user saves (lib/desktop/files) rather than share them
  static Future<void> shareLogs(BuildContext context, {bool toFile = false}) async {
    final tempDir = await getTemporaryDirectory();
    // Windows refuses the colons of an ISO 8601 time in a file name
    final dateTime = CurrentPlatform.isDesktop ? fileNameDate(DateTime.now()) : DateTime.now().toIso8601String();
    final filePath = '${tempDir.path}/Immich_log_$dateTime.log';
    final logFile = await File(filePath).create();
    final io = logFile.openWrite();
    try {
      // Write messages
      for (final m in await LogService.I.getMessages()) {
        final created = m.createdAt;
        final level = m.level.name.padRight(8);
        final logger = (m.logger ?? "<UNKNOWN_LOGGER>").padRight(20);
        final message = m.message;
        final error = m.error == null ? "" : " ${m.error} |";
        final stack = m.stack == null ? "" : "\n${m.stack!}";
        io.write('$created | $level | $logger | $message |$error$stack\n');
      }
    } finally {
      await io.flush();
      await io.close();
    }

    if (!context.mounted) {
      return;
    }

    // Linux has no share sheet for files: its share button saves the file too
    if (toFile || CurrentPlatform.isLinux) {
      await saveLogFile(logFile);
      await logFile.delete();
      return;
    }

    final box = context.findRenderObject() as RenderBox?;

    // Share file
    await Share.shareXFiles(
      [XFile(filePath)],
      subject: "Immich logs $dateTime",
      sharePositionOrigin: box!.localToGlobal(Offset.zero) & box.size,
    ).then((value) => logFile.delete());
  }
}
