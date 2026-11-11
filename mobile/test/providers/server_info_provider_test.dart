// The version check against the server: "App update available" only when the server is a major release ahead of the
// app. A newer minor or a prerelease of the same release asks for nothing, so that the notice does not come back for
// every user between two upstream syncs; an older server stays "server out of date" for an admin who knows the latest
// release, as upstream has it.

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../service.mocks.dart';
import '../unit/factories/user_factory.dart';

void main() {
  late MockServerInfoService service;
  late ProviderContainer container;

  final user = UserFactory.createDto();
  final admin = user.copyWith(isAdmin: true);

  void appVersion(String version) => PackageInfo.setMockInitialValues(
    appName: 'Immuch360',
    packageName: 'app.alextran.immich',
    version: version,
    buildNumber: '3030043',
    buildSignature: '',
  );

  ServerVersion server(int major, int minor, int patch, [int? prerelease]) =>
      ServerVersion(major: major, minor: minor, patch: patch, prerelease: prerelease);

  setUp(() {
    service = MockServerInfoService();
    container = ProviderContainer(overrides: [serverInfoServiceProvider.overrideWithValue(service)]);
    appVersion('3.4.0');
  });

  tearDown(() => container.dispose());

  Future<VersionStatus> statusOn(ServerVersion version, {ServerVersion? latest}) async {
    when(() => service.getServerVersion()).thenAnswer((_) async => version);
    final notifier = container.read(serverInfoProvider.notifier);
    await notifier.getServerVersion();
    if (latest != null) {
      notifier.handleReleaseInfo(version, latest);
      // The check of a release event runs without being awaited
      await pumpEventQueue();
    }
    return container.read(serverInfoProvider).versionStatus;
  }

  bool warningFor(UserDto? user) => container.read(versionWarningPresentProvider(user));

  group('app 3.4.0', () {
    test('on a 3.4.0 server: up to date', () async {
      expect(await statusOn(server(3, 4, 0)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
    });

    test('on a newer patch, 3.4.2: up to date, as before', () async {
      expect(await statusOn(server(3, 4, 2)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
    });

    test('on a newer minor, 3.5.0, and its prerelease 3.5.0-rc.1: no "App update available"', () async {
      expect(await statusOn(server(3, 5, 0)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
      expect(warningFor(admin), isFalse);
      expect(await statusOn(server(3, 5, 0, 1)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
    });

    test('on a 3.4.0-rc.1 server, a prerelease of the same release: no "App update available"', () async {
      final status = await statusOn(server(3, 4, 0, 1));
      expect(status, isNot(VersionStatus.clientOutOfDate));
      expect(warningFor(user), isFalse);
    });

    test('on a 3.3.x server: "server out of date", shown to an admin who knows the latest release only', () async {
      expect(await statusOn(server(3, 3, 6)), VersionStatus.serverOutOfDate);
      expect(warningFor(user), isFalse);
      expect(warningFor(admin), isFalse, reason: 'no latest release known yet');

      expect(await statusOn(server(3, 3, 0), latest: server(3, 4, 0)), VersionStatus.serverOutOfDate);
      expect(warningFor(user), isFalse);
      expect(warningFor(admin), isTrue);
    });

    test('on a 4.0.0 server, a major ahead: "App update available" for everyone', () async {
      expect(await statusOn(server(4, 0, 0)), VersionStatus.clientOutOfDate);
      expect(warningFor(user), isTrue);
      expect(warningFor(admin), isTrue);
    });

    test('on a 4.0.0-rc.1 server, a major ahead too: "App update available"', () async {
      expect(await statusOn(server(4, 0, 0, 1)), VersionStatus.clientOutOfDate);
      expect(warningFor(user), isTrue);
    });
  });

  group('an app on a prerelease or an older minor', () {
    test('app 3.4.0-rc.0 on a 3.4.0 server, the gap of build 44 (3.3.0-rc.0 on 3.3.x): up to date', () async {
      appVersion('3.4.0-rc.0');
      expect(await statusOn(server(3, 4, 0)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
    });

    test('app 3.3.0-rc.0 on a 3.4.0 server: up to date, no notice', () async {
      appVersion('3.3.0-rc.0');
      expect(await statusOn(server(3, 4, 0)), VersionStatus.upToDate);
      expect(warningFor(user), isFalse);
    });
  });

  test('no answer from the server: the error stays a warning', () async {
    when(() => service.getServerVersion()).thenAnswer((_) async => null);
    await container.read(serverInfoProvider.notifier).getServerVersion();
    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.error);
    expect(warningFor(user), isTrue);
  });
}
