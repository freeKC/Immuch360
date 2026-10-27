// What closing the window of Immuch360 Desktop would stop (design 1.8): the uploads (the backup, an upload chosen by
// hand, an upload from a network share), the share of the computer and the 3D conversions (design-final 2026-10-26,
// section 2.6.5), read only from the providers that exist, so that asking creates none of them.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
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

/// The queue of the 3D conversions with jobs in [states]
class _Conversions extends ConversionQueueNotifier {
  _Conversions(this.states);

  final List<ConversionState> states;

  @override
  ConversionQueueState build() => ConversionQueueState(
    jobs: [
      for (final (index, state) in states.indexed)
        ConversionJob(
          id: 'conversion-$index',
          source: LocalFileSource('/photos/$index.jpg'),
          batchIndex: index + 1,
          batchSize: states.length,
          target: ConversionTarget.nextTo('/photos/$index.jpg'),
          state: state,
        ),
    ],
  );
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
    expect(container.exists(conversionQueueProvider), isFalse);
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

  test('the 3D conversions while a photo is converted or waits, not once they all ended', () {
    Set<DesktopCloseReason> reasonsWith(List<ConversionState> states) {
      final container = ProviderContainer(
        overrides: [conversionQueueProvider.overrideWith(() => _Conversions(states))],
      );
      addTearDown(container.dispose);
      container.read(conversionQueueProvider);
      return container.read(desktopCloseReasonsProvider)();
    }

    expect(reasonsWith([ConversionState.done, ConversionState.depth]), {DesktopCloseReason.conversions});
    expect(reasonsWith([ConversionState.failed, ConversionState.waiting]), {DesktopCloseReason.conversions});
    expect(
      reasonsWith([ConversionState.done, ConversionState.skipped, ConversionState.cancelled, ConversionState.failed]),
      isEmpty,
    );
    expect(reasonsWith([]), isEmpty);
  });
}
