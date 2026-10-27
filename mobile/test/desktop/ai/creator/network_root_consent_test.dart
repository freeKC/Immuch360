import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/network_root_consent.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  DesktopAiSettingsStore store() => DesktopAiSettingsStore(settingsDirectory: () async => support);

  setUp(() => support = Directory.systemTemp.createTempSync('ai_consent'));
  tearDown(() => support.deleteSync(recursive: true));

  test('no network folder is allowed at first', () async {
    final consent = NetworkRootConsent(store: store());

    expect(await consent.allowed(), isEmpty);
    expect(await consent.isAllowed('net-//nas/photos:/2024'), isFalse);
  });

  test('a yes is kept in desktop_ai.json and found again by the next start', () async {
    final settings = await NetworkRootConsent(store: store()).allow('net-//nas/photos:/2024');

    expect(settings.networkRootsAllowed, ['net-//nas/photos:/2024']);
    final kept = jsonDecode(File(p.join(support.path, DesktopAiSettingsStore.fileName)).readAsStringSync()) as Map;
    expect(kept['networkRootsAllowed'], ['net-//nas/photos:/2024']);
    final later = NetworkRootConsent(store: store());
    expect(await later.isAllowed('net-//nas/photos:/2024'), isTrue);
    expect(await later.isAllowed('net-//nas/photos:/2024/Holidays'), isTrue);
    expect(await later.isAllowed('net-//nas/photos:/2023'), isFalse);
  });

  test('the same yes twice is kept once', () async {
    final consent = NetworkRootConsent(store: store());
    await consent.allow('net-//nas/photos');
    await consent.allow('net-//nas/photos');

    expect(await consent.allowed(), ['net-//nas/photos']);
  });

  test('a yes taken back: the next conversion asks again, the others stay', () async {
    final consent = NetworkRootConsent(store: store());
    await consent.allow('net-//nas/photos:/2024');
    await consent.allow('net-//nas/videos');

    final settings = await consent.withdraw('net-//nas/photos:/2024');

    expect(settings.networkRootsAllowed, ['net-//nas/videos']);
    expect(await NetworkRootConsent(store: store()).isAllowed('net-//nas/photos:/2024'), isFalse);
    expect(await NetworkRootConsent(store: store()).isAllowed('net-//nas/videos:/clips'), isTrue);
  });

  test('what a yes covers: its root and the folders under it; a volume, every folder of it', () {
    // A root of the library
    expect(consentCovers('net-//nas/photos:/2024', 'net-//nas/photos:/2024'), isTrue);
    expect(consentCovers('net-//nas/photos:/2024', 'net-//nas/photos:/2024/june'), isTrue);
    expect(consentCovers('net-//nas/photos:/2024', 'net-//nas/photos:/2025'), isFalse);
    expect(consentCovers('net-//nas/photos:/2024', 'net-//nas/photos:/20245'), isFalse);
    expect(consentCovers('net-//nas/photos:/2024', 'net-//nas/photos:/'), isFalse);
    // The volume of a file opened with the program
    expect(consentCovers('net-//nas/photos', 'net-//nas/photos:/'), isTrue);
    expect(consentCovers('net-//nas/photos', 'net-//nas/photos:/2024/june'), isTrue);
    expect(consentCovers('net-//nas/photos', 'net-//nas/photos2:/2024'), isFalse);
    expect(consentCovers('net-//nas/photos', 'net-//other/photos:/'), isFalse);
    // A mount point of Linux
    expect(consentCovers('net-//nas/photos', 'net-//nas/photos:/a'), isTrue);
    expect(consentGiven(['net-z:', 'net-//nas/photos:/2024'], 'net-//nas/photos:/2024/x'), isTrue);
    expect(consentGiven(const [], 'net-//nas/photos:/2024'), isFalse);
  });
}
