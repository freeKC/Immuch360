// What the app does after a scan that changed the folder library (folder_library_controller.dart), with the sync
// manager and the keeper of the album of the generated photos replaced: the album leaves the backup after the local
// tables are brought up to date and before anything is hashed, so before the backup starts. The end of a sync also
// tells the keeper, but that check is not awaited: the order holds by this one.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

import '../../repository.mocks.dart';
import '../../service.mocks.dart';

void main() {
  late List<String> steps;
  late MockBackgroundSyncManager manager;

  setUp(() {
    steps = [];
    manager = MockBackgroundSyncManager();
    when(() => manager.syncLocal(full: any(named: 'full'))).thenAnswer((_) async => steps.add('syncLocal'));
    when(() => manager.hashAssets()).thenAnswer((_) async => steps.add('hashAssets'));
  });

  ProviderContainer app({required bool hasServer}) {
    final container = ProviderContainer(
      overrides: [
        hasServerProvider.overrideWithValue(hasServer),
        localSessionRefreshProvider.overrideWithValue(({bool full = false}) async => steps.add('localSession')),
        authProvider.overrideWith(_SignedIn.new),
        backgroundSyncProvider.overrideWithValue(manager),
        generatedAlbumKeeperProvider.overrideWithValue(_RecordingKeeper(steps)),
        galleryPermissionNotifier.overrideWith((_) => _Permission()),
        backupProvider.overrideWith(
          (_) => BackupNotifier(MockForegroundUploadService(), MockBackgroundUploadService(), UploadSpeedManager()),
        ),
        appConfigProvider.overrideWithValue(defaultConfig),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('with a server: the local sync, then the album out of the backup, then the hashing', () async {
    await app(hasServer: true).read(libraryChangesPusherProvider)();

    expect(steps, ['syncLocal', 'exclusion', 'hashAssets']);
  });

  test('in a session without a server: the album leaves the backup there too', () async {
    await app(hasServer: false).read(libraryChangesPusherProvider)();

    expect(steps, ['localSession', 'exclusion']);
  });

  testWidgets('the host of the library keeps the keeper alive, so it hears every sync that ends', (tester) async {
    var kept = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          folderLibraryWatcherProvider.overrideWithValue(null),
          generatedAlbumKeeperProvider.overrideWith((ref) {
            kept++;
            return _RecordingKeeper(steps);
          }),
        ],
        child: const FolderLibraryHost(child: SizedBox()),
      ),
    );

    expect(kept, 1);
  });
}

class _RecordingKeeper extends Fake implements GeneratedAlbumKeeper {
  _RecordingKeeper(this._steps);

  final List<String> _steps;

  @override
  Future<AiGeneratedAlbumState> ensureExcluded() async {
    _steps.add('exclusion');
    return AiGeneratedAlbumState.excluded;
  }
}

class _SignedIn extends AuthNotifier {
  _SignedIn(Ref ref)
    : super(
        MockAuthService(),
        MockApiService(),
        MockUserService(),
        MockSecureStorageService(),
        MockWidgetService(),
        ref,
      ) {
    state = const AuthState(
      deviceId: 'device-1',
      userId: 'user-1',
      userEmail: 'user@example.com',
      name: 'User',
      profileImagePath: '',
      isAdmin: false,
      isAuthenticated: true,
    );
  }
}

class _Permission extends GalleryPermissionNotifier {
  _Permission() : super(DevicePermissionService(MockPermissionRepository()));

  @override
  Future<DevicePermissionStatus> getGalleryPermissionStatus() async => state;
}
