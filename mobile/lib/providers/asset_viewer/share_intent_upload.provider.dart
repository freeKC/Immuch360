import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_import.page.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/share_intent_service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final shareIntentUploadProvider = StateNotifierProvider<ShareIntentUploadStateNotifier, List<ShareIntentAttachment>>(
  (ref) => ShareIntentUploadStateNotifier(
    ref.watch(appRouterProvider),
    ref.read(foregroundUploadServiceProvider),
    ref.read(shareIntentServiceProvider),
    toasts: ref.read(toastServiceProvider),
  ),
);

/// Whether the file named [fileName] is a proxy, flight data or sound file a camera or a drone writes beside its media
/// (see NetworkEntry.companionExtensions): never uploaded, the server refuses them
bool isCompanionFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot >= 0 && NetworkEntry.companionExtensions.contains(fileName.substring(dot + 1).toLowerCase());
}

/// The text of the file at [path] when it is a settings file (a .json file that says so), null otherwise
String? readSettingsFileAttachment(String path) {
  if (!path.toLowerCase().endsWith('.json')) {
    return null;
  }
  try {
    final file = File(path);
    if (file.lengthSync() > settingsFileMaxBytes) {
      return null;
    }
    final text = file.readAsStringSync();
    return SettingsFile.looksLikeSettingsFile(text) ? text : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

class ShareIntentUploadStateNotifier extends StateNotifier<List<ShareIntentAttachment>> {
  final AppRouter router;
  final ForegroundUploadService _foregroundUploadService;
  final ShareIntentService _shareIntentService;
  final ToastService? _toasts;
  final Logger _logger = Logger('ShareIntentUploadStateNotifier');

  ShareIntentUploadStateNotifier(this.router, this._foregroundUploadService, this._shareIntentService, {this._toasts})
    : super([]);

  void init() {
    _shareIntentService.onSharedMedia = onSharedMedia;
    _shareIntentService.init();
  }

  void onSharedMedia(List<ShareIntentAttachment> received) {
    // A settings file shared to the app (on iOS: Files, Share, Immuch360) opens the restore page, never an upload
    var shared = received;
    for (final attachment in received) {
      final text = readSettingsFileAttachment(attachment.path);
      if (text != null) {
        shared = received.where((other) => other != attachment).toList();
        unawaited(
          router.navigatorKey.currentState?.push(
            MaterialPageRoute<void>(builder: (_) => SettingsFileImportPage(initialText: text)),
          ),
        );
        break;
      }
    }
    // A file manager may share the .LRF proxy of a DJI video as a video, or its .SRT along with it: the server refuses
    // them, and they are no media of their own
    final attachments = shared.where((attachment) => !isCompanionFileName(attachment.fileName)).toList();
    final skipped = shared.length - attachments.length;
    if (skipped > 0) {
      _logger.info('Skipped $skipped proxy or flight data files shared to the app');
      unawaited(Future.sync(() => _toasts?.info(StaticTranslations.instance.share_skipped_companions(count: skipped))));
    }
    if (attachments.isEmpty) {
      return;
    }
    router.removeWhere((route) => route.name == "ShareIntentRoute");
    clearAttachments();
    addAttachments(attachments);
    unawaited(router.push(ShareIntentRoute(attachments: attachments)));
  }

  void addAttachments(List<ShareIntentAttachment> attachments) {
    if (attachments.isEmpty) {
      return;
    }
    state = [...state, ...attachments];
  }

  void removeAttachment(ShareIntentAttachment attachment) {
    final updatedState = state.where((element) => element != attachment).toList();
    if (updatedState.length != state.length) {
      state = updatedState;
    }
  }

  void clearAttachments() {
    if (state.isEmpty) {
      return;
    }

    state = [];
  }

  Future<void> uploadAll(List<File> files) async {
    for (final file in files) {
      final fileId = p.hash(file.path).toString();
      _updateStatus(fileId, UploadStatus.running);
    }

    await _foregroundUploadService.uploadShareIntent(
      files,
      onProgress: (fileId, bytes, totalBytes) {
        final progress = totalBytes > 0 ? bytes / totalBytes : 0.0;
        _updateProgress(fileId, progress);
      },
      onSuccess: (fileId, _) {
        _updateStatus(fileId, UploadStatus.complete, progress: 1.0);
      },
      onError: (fileId, _) {
        _updateStatus(fileId, UploadStatus.failed);
      },
    );
  }

  void _updateStatus(String fileId, UploadStatus status, {double? progress}) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id)
          attachment.copyWith(status: status, uploadProgress: progress ?? attachment.uploadProgress)
        else
          attachment,
    ];
  }

  void _updateProgress(String fileId, double progress) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id) attachment.copyWith(uploadProgress: progress) else attachment,
    ];
  }
}
