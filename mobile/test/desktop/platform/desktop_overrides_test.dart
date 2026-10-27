import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/platform/desktop_overrides.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/services/widget.service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // home_widget has no implementation on a computer: each of its calls ends in a MissingPluginException, and the sign
  // in writes the credentials of the home screen widget (AuthNotifier.saveAuthInfo), so no sign in could succeed
  group('home screen widget on a computer', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer(overrides: desktopOverrides()));

    tearDown(() => container.dispose());

    test('writing the credentials at sign in completes without a plugin', () async {
      await expectLater(
        container.read(widgetServiceProvider).writeCredentials('https://photos.example.org', 'TEST-TOKEN', null),
        completes,
      );
    });

    test('clearing them at sign out completes without a plugin', () async {
      await expectLater(container.read(widgetServiceProvider).clearCredentials(), completes);
    });
  });

  // The files given to the program come as paths, not as the view intents of a phone, and the other file of an X3
  // pair opened with it is next to it on the disk
  test('the files given to the program open through the desktop handler, X3 pairs next to them', () {
    final container = ProviderContainer(overrides: desktopOverrides());
    addTearDown(container.dispose);

    expect(container.read(viewIntentHandlerProvider), isA<DesktopOpenFilesHandler>());
    expect(container.read(openedFileSiblingProvider), OpenedFiles.sibling);
  });

  test('the AI components of a computer in its own folder, those of the Quest in the support folder', () {
    final desktop = ProviderContainer(overrides: desktopOverrides());
    final quest = ProviderContainer();
    addTearDown(desktop.dispose);
    addTearDown(quest.dispose);

    expect(desktop.read(aiComponentsFolderProvider), desktopAiComponentsFolder);
    expect(quest.read(aiComponentsFolderProvider), supportAiComponentsFolder);
  });

  test('the phones look for the other file of an X3 pair in the database only', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(openedFileSiblingProvider), isNull);
  });
}
