// "Delete from device" on a computer: hidden until the files can go to the system's trash (Design 1.10, 7.2). The
// phones keep their behaviour, which test/unit/presentation/actions covers.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/lock.action.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;
  late MockAssetService assetService;
  late MockCleanupService cleanupService;

  setUp(() async {
    context = await PresentationContext.create();
    assetService = context.service.asset.service;
    cleanupService = context.service.cleanup.service;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  RemoteAsset merged() => RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: 'local-1');

  for (final platform in const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    group(platform.name, () {
      testWidgets('no "Delete from device" for a backed up file', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpTestWidget(
          context,
          const ActionIconButton(action: CleanupLocalAction(source: .timeline)),
          overrides: context.selected({LocalAssetFactory.create(remoteId: 'remote')}),
        );
        expect(find.byType(ImmichIconButton), findsNothing);
        // Has to be cleared inside the body; the framework asserts on it before tearDown runs
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('no delete at all for a file only on this computer', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpTestWidget(
          context,
          const ActionIconButton(action: DeleteAction(source: .timeline)),
          overrides: context.selected({LocalAssetFactory.create()}),
        );
        expect(find.byType(ImmichIconButton), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('deleting a backed up photo trashes the server copy and leaves the file', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final asset = merged();
        await tester.pumpTestAction(
          context,
          const DeleteAction(source: .timeline),
          overrides: context.selected({asset}),
        );
        await tester.pumpAndSettle();

        verify(() => assetService.trash([asset.id])).called(1);
        verifyNever(() => cleanupService.deleteLocalAssets(any()));
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('locking warns of no deletion and says the file was kept', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final asset = merged();
        await tester.pumpTestAction(context, const LockAction(source: .timeline), overrides: context.selected({asset}));
        await tester.pumpAndSettle();

        expect(find.byType(ConfirmDialog), findsNothing);
        verify(() => assetService.update([asset.id], visibility: const .some(.locked))).called(1);
        expect(
          find.text(StaticTranslations.instance.move_to_lock_folder_partial_prompt(count: 1)),
          findsOneWidget,
          reason: 'the desktop repository deletes nothing, so the copy is reported as kept',
        );
        debugDefaultTargetPlatformOverride = null;
      });
    });
  }

  testWidgets('a phone still offers "Delete from device" for a backed up file', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpTestWidget(
      context,
      const ActionIconButton(action: CleanupLocalAction(source: .timeline)),
      overrides: context.selected({LocalAssetFactory.create(remoteId: 'remote')}),
    );
    expect(find.byType(ImmichIconButton), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
