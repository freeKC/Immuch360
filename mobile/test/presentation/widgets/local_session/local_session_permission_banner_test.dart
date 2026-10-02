import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/presentation/widgets/local_session/local_session_permission_banner.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../../repository.mocks.dart';
import '../../../widget_tester_extensions.dart';

/// A gallery permission notifier whose answers are scripted: [afterRequest] is the status the system returns when
/// asked again, [afterSettings] the one read back after the settings page.
class _GalleryPermission extends GalleryPermissionNotifier {
  _GalleryPermission(this.calls, DevicePermissionStatus initial, {required this.afterRequest, this.afterSettings})
    : super(DevicePermissionService(MockPermissionRepository())) {
    state = initial;
  }

  final List<String> calls;
  final DevicePermissionStatus afterRequest;
  final DevicePermissionStatus? afterSettings;

  @override
  Future<DevicePermissionStatus> getGalleryPermissionStatus() async {
    calls.add('status');
    return state = afterSettings ?? state;
  }

  @override
  Future<DevicePermissionStatus> requestGalleryPermission() async {
    calls.add('request');
    return state = afterRequest;
  }
}

void main() {
  late List<String> calls;
  late MockPermissionRepository repository;

  setUp(() {
    calls = [];
    repository = MockPermissionRepository();
    when(() => repository.openSettings()).thenAnswer((_) async {
      calls.add('settings');
      return true;
    });
  });

  Future<void> pumpBanner(WidgetTester tester, _GalleryPermission notifier) => tester.pumpConsumerWidget(
    const LocalSessionPermissionBanner(),
    overrides: [
      galleryPermissionNotifier.overrideWith((_) => notifier),
      permissionRepositoryProvider.overrideWithValue(repository),
      localSessionRefreshProvider.overrideWithValue(({bool full = false}) async => calls.add('refresh full:$full')),
    ],
  );

  testWidgets('explains the situation and offers to ask again when the permission was refused', (tester) async {
    await pumpBanner(
      tester,
      _GalleryPermission(calls, DevicePermissionStatus.denied, afterRequest: DevicePermissionStatus.granted),
    );

    expect(find.text('The app cannot see the photos of this device'), findsOneWidget);
    expect(find.textContaining('nothing leaves the device'), findsOneWidget);
    expect(find.text('Allow access'), findsOneWidget);
    expect(find.text('Open the settings'), findsOneWidget);
  });

  testWidgets('asks the system again and indexes the device once the permission is granted', (tester) async {
    await pumpBanner(
      tester,
      _GalleryPermission(calls, DevicePermissionStatus.denied, afterRequest: DevicePermissionStatus.granted),
    );
    calls.clear();

    await tester.tap(find.byKey(const Key('local_session_permission_allow')));
    await tester.pumpAndSettle();

    expect(calls, ['request', 'refresh full:true']);
  });

  testWidgets('does not index the device when the permission stays refused', (tester) async {
    await pumpBanner(
      tester,
      _GalleryPermission(calls, DevicePermissionStatus.denied, afterRequest: DevicePermissionStatus.denied),
    );
    calls.clear();

    await tester.tap(find.byKey(const Key('local_session_permission_allow')));
    await tester.pumpAndSettle();

    expect(calls, ['request']);
  });

  testWidgets('opens the system settings when the system no longer asks, then reads the permission back', (
    tester,
  ) async {
    await pumpBanner(
      tester,
      _GalleryPermission(
        calls,
        DevicePermissionStatus.permanentlyDenied,
        afterRequest: DevicePermissionStatus.permanentlyDenied,
        afterSettings: DevicePermissionStatus.granted,
      ),
    );
    calls.clear();

    // The main button is labelled after the settings in that state
    expect(find.widgetWithText(FilledButton, 'Open the settings'), findsOneWidget);
    expect(find.text('Allow access'), findsNothing);

    await tester.tap(find.byKey(const Key('local_session_permission_allow')));
    await tester.pumpAndSettle();

    expect(calls, ['request', 'settings', 'status', 'refresh full:true']);
  });

  testWidgets('the secondary button only opens the settings', (tester) async {
    await pumpBanner(
      tester,
      _GalleryPermission(calls, DevicePermissionStatus.denied, afterRequest: DevicePermissionStatus.granted),
    );
    calls.clear();

    await tester.tap(find.byKey(const Key('local_session_permission_settings')));
    await tester.pumpAndSettle();

    expect(calls, ['settings']);
  });
}
