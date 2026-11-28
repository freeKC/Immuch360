// Share on a computer (lib/desktop/share/desktop_share.dart): the button opens the menu that names each way rather
// than the share sheet of share_plus, on Windows, macOS and Linux; its long press asks the quality first, as on a phone.
// The phones keep their Share untouched (share_action_test.dart, which runs as Android).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/share/desktop_share.dart';
import 'package:immich_mobile/desktop/share/system_share_sheet.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _NoSheet implements SystemShareSheet {
  @override
  Future<bool> supported() async => false;

  @override
  SystemShare share(List<String> paths, {required String title, Rect? origin}) => throw UnimplementedError();
}

void main() {
  late PresentationContext context;

  setUp(() async {
    resetDesktopShare();
    context = await PresentationContext.create();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  late BuildContext actionContext;
  late WidgetRef actionRef;

  Future<void> pumpShare(WidgetTester tester) => tester.pumpTestWidget(
    context,
    Consumer(
      builder: (widgetContext, ref, _) {
        actionContext = widgetContext;
        actionRef = ref;
        return const ActionIconButton(action: ShareAction(source: .timeline));
      },
    ),
    overrides: [
      ...context.selected({RemoteAssetFactory.create(ownerId: context.currentUser.id)}),
      systemShareSheetProvider.overrideWithValue(_NoSheet()),
    ],
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  void verifyNoSheetShare() => verifyNever(
    () => context.repository.assetMedia.api.shareAssets(
      any(),
      any(),
      fileType: any(named: 'fileType'),
      cancelCompleter: any(named: 'cancelCompleter'),
      onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
    ),
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('${platform.name}: the button opens the Share menu, never the share sheet of a phone', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await pumpShare(tester);

      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);

      expect(find.byKey(const Key('desktop_share_copy')), findsOneWidget);
      expect(find.byKey(const Key('desktop_share_saveToFolder')), findsOneWidget);
      expect(find.byKey(const Key('desktop_share_systemSheet')), findsNothing, reason: 'the system said it has none');
      verifyNoSheetShare();
      Navigator.of(tester.element(find.byKey(const Key('desktop_share_copy')))).pop();
      await settle(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('its long press asks the quality, then opens the menu with it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShare(tester);
    final item = const ShareAction(source: .timeline).create(actionContext, actionRef)!;
    expect(item.onSecondaryAction, isNotNull);

    final asked = Future.sync(item.onSecondaryAction!);
    await settle(tester);
    await tester.tap(find.byKey(const Key('desktop_share_preview')));
    await settle(tester);
    expect(find.byKey(const Key('desktop_share_quality')), findsOneWidget);
    expect(find.text(StaticTranslations.instance.share_preview), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const Key('desktop_share_copy')))).pop();
    await settle(tester);
    await asked;
    verifyNoSheetShare();
    debugDefaultTargetPlatformOverride = null;
  });
}
