import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/local_album_bottom_sheet.widget.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/local_asset_factory.dart';
import '../presentation_context.dart';

/// The selection sheets in a session without a server: nobody is signed in, so the actions on owned assets hide
/// rather than fail, nothing offers to upload, and there are no albums to add to.
void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
    // Nobody is signed in, and the session is the one the login page starts without a server
    when(context.service.user.tryGetMyUser).thenReturn(null);
    await StoreService.I.put(StoreKey.localSession, true);
  });

  tearDown(() async {
    await StoreService.I.delete(StoreKey.localSession);
    await context.dispose();
  });

  void expectDeviceActionsOnly(WidgetTester tester) {
    final t = StaticTranslations.instance;
    expect(tester.takeException(), isNull);
    expect(find.text(t.share), findsOneWidget);
    expect(find.text(t.trash), findsOneWidget, reason: 'the delete action, which removes the device copy');
    for (final label in [t.upload, t.favorite, t.archive, t.move_to_locked_folder, t.add_to_album]) {
      expect(find.text(label), findsNothing, reason: label);
    }
  }

  testWidgets('GeneralBottomSheet offers the device actions only, and no albums', (tester) async {
    await tester.pumpTestWidget(
      context,
      const GeneralBottomSheet(),
      overrides: context.selected({LocalAssetFactory.create()}),
    );

    expectDeviceActionsOnly(tester);
  });

  testWidgets('LocalAlbumBottomSheet offers the device actions only, and no albums', (tester) async {
    await tester.pumpTestWidget(
      context,
      const LocalAlbumBottomSheet(),
      overrides: context.selected({LocalAssetFactory.create()}),
    );

    expectDeviceActionsOnly(tester);
  });
}
