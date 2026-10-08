// What a computer leaves out (design 7.1 and 7.2), next to the entries the groundwork already hid (gyroscope, maps,
// OAuth, free up space, notifications, the gallery permission): the haptics setting, Cast in the viewer's menu,
// "Delete from device", and the map of the location editor, whose coordinates stay. The phones keep every one of them.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/providers/infrastructure/device_features.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';
import 'package:immich_mobile/widgets/common/location_picker.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';

import '../../unit/presentation/presentation_context.dart';

const _desktops = [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux];

ActionButtonContext _viewerContext(BaseAsset asset) => ActionButtonContext(
  asset: asset,
  isOwner: true,
  isArchived: false,
  isStacked: false,
  isInLockedView: false,
  currentAlbum: null,
  advancedTroubleshooting: false,
  source: ActionSource.viewer,
);

final _remote = RemoteAsset(
  id: 'remote',
  name: 'remote.jpg',
  ownerId: 'owner',
  checksum: 'checksum',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  isEdited: false,
);

final _merged = LocalAsset(
  id: 'local',
  remoteId: 'remote',
  name: 'local.jpg',
  checksum: 'checksum',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Cast and "Delete from device" stay on the phones only', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final phone = !_desktops.contains(platform);
      expect(ActionButtonType.cast.shouldShow(_viewerContext(_remote)), phone, reason: platform.name);
      expect(ActionButtonType.deleteLocal.shouldShow(_viewerContext(_merged)), phone, reason: platform.name);
    }
  });

  test('the capabilities a computer answers no to, and the phones yes', () {
    DeviceFeatures read() {
      final container = ProviderContainer(overrides: [tvModeProvider.overrideWithValue(false)]);
      addTearDown(container.dispose);
      return container.read(deviceFeaturesProvider);
    }

    for (final platform in _desktops) {
      debugDefaultTargetPlatformOverride = platform;
      final computer = read();
      expect([computer.haptics, computer.cast, computer.batteryOptimisation], everyElement(isFalse));
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final phone = read();
    expect([phone.haptics, phone.cast, phone.batteryOptimisation], everyElement(isTrue));
  });

  group('the preferences', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    testWidgets('a computer has no haptics setting', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpTestWidget(context, const PreferenceSetting());
      expect(find.text('Haptic Feedback'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps it', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpTestWidget(context, const PreferenceSetting());
      expect(find.text('Haptic Feedback'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the location editor', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async => context.dispose());

    Future<void> openEditor(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLocationPicker(context: context),
            child: const Text('edit'),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      expect(find.text('Location'), findsOneWidget);
    }

    testWidgets('a computer has no map to choose on, the coordinates stay', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await openEditor(tester);
      expect(find.text('Choose on map'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a phone keeps its map', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await openEditor(tester);
      expect(find.text('Choose on map'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
