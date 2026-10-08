// What closing the window of Immuch360 Desktop would stop (design 1.8): the uploads (the backup, an upload chosen by
// hand, an upload from a network share) and the share of the computer, read only from the providers that exist, so
// that asking creates none of them.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

class _ForegroundUploads extends Mock implements ForegroundUploadService {}

class _BackgroundUploads extends Mock implements BackgroundUploadService {}

/// The backup with [items] in its list of uploads
class _Backup extends BackupNotifier {
  _Backup(Map<String, UploadStatus> items) : super(_ForegroundUploads(), _BackgroundUploads(), UploadSpeedManager()) {
    state = state.copyWith(uploadItems: items);
  }
}

UploadStatus _upload(String id, {bool failed = false}) => UploadStatus(
  taskId: id,
  filename: '$id.jpg',
  progress: 0.5,
  fileSize: 100,
  networkSpeedAsString: '',
  isFailed: failed,
);

class _RunningNetworkUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState(isRunning: true, total: 3);
}

class _SharingController extends PhoneShareController {
  @override
  PhoneShareState build() => const PhoneShareState(status: PhoneShareStatus.on);
}

void main() {
  test('nothing runs in a fresh app, and asking creates no provider', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(desktopCloseReasonsProvider)(), isEmpty);
    expect(container.exists(backupProvider), isFalse);
    expect(container.exists(networkUploadProvider), isFalse);
    expect(container.exists(phoneShareProvider), isFalse);
    expect(container.exists(manualUploadCancelTokenProvider), isFalse);
  });

  test('the backup while it sends a file, not once only failures are left in its list', () {
    ProviderContainer containerWith(Map<String, UploadStatus> items) {
      final container = ProviderContainer(overrides: [backupProvider.overrideWith((ref) => _Backup(items))]);
      addTearDown(container.dispose);
      container.read(backupProvider);
      return container;
    }

    expect(containerWith({'a': _upload('a'), 'b': _upload('b', failed: true)}).read(desktopCloseReasonsProvider)(), {
      DesktopCloseReason.uploads,
    });
    expect(containerWith({'b': _upload('b', failed: true)}).read(desktopCloseReasonsProvider)(), isEmpty);
    expect(containerWith({}).read(desktopCloseReasonsProvider)(), isEmpty);
  });

  test('an upload chosen by hand', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final token = Completer<void>();
    container.read(manualUploadCancelTokenProvider.notifier).state = token;

    expect(container.read(desktopCloseReasonsProvider)(), {DesktopCloseReason.uploads});

    container.read(manualUploadCancelTokenProvider.notifier).state = null;
    expect(container.read(desktopCloseReasonsProvider)(), isEmpty);
  });

  test('an upload from a network share', () {
    final container = ProviderContainer(overrides: [networkUploadProvider.overrideWith(_RunningNetworkUpload.new)]);
    addTearDown(container.dispose);
    container.read(networkUploadProvider);

    expect(container.read(desktopCloseReasonsProvider)(), {DesktopCloseReason.uploads});
  });

  test('the share of the computer on the network', () {
    final container = ProviderContainer(overrides: [phoneShareProvider.overrideWith(_SharingController.new)]);
    addTearDown(container.dispose);
    container.read(phoneShareProvider);

    expect(container.read(desktopCloseReasonsProvider)(), {DesktopCloseReason.computerShare});
  });
}
