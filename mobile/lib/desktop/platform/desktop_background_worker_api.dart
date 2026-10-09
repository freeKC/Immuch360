// The background worker on the computers. The phones back up from a background engine that the system wakes up
// (WorkManager, BGTaskScheduler); a computer has no such scheduler for a Flutter app, so the backup runs while the
// app is open and these APIs do nothing.

import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';

class DesktopBackgroundWorkerFgHostApi implements BackgroundWorkerFgHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> enable() async {}

  @override
  Future<void> saveNotificationMessage(String title, String body) async {}

  @override
  Future<void> configure(BackgroundWorkerSettings settings) async {}

  @override
  Future<void> disable() async {}

  /// The app is never started by a scheduler on a computer
  @override
  Future<bool> wasLaunchedInBackground() async => false;
}

class DesktopBackgroundWorkerBgHostApi implements BackgroundWorkerBgHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> onInitialized() async {}

  @override
  Future<void> close() async {}
}

/// The lock between the foreground and the background engines is Android's (BackgroundWorkerLockService only calls
/// it there); nothing to lock with a single engine
class DesktopBackgroundWorkerLockApi implements BackgroundWorkerLockApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> lock() async {}

  @override
  Future<void> unlock() async {}
}
