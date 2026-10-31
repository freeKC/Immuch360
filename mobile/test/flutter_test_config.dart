import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:logging/logging.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Logger.root.level = Level.OFF;
  EasyLocalization.logger.enableBuildModes = [];
  // ignore: banned-usage
  debugPrint = (String? message, {int? wrapWidth}) {};
  // No database file for the watch progress: its rows live in memory, a test that needs one gives its own repository
  watchDatabaseOpener = () => Future.error(UnsupportedError('no database file under flutter test'));
  return testMain();
}
