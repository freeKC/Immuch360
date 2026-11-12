import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/providers/asset_viewer/share_intent_upload.provider.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('share_settings'));
  tearDown(() => folder.deleteSync(recursive: true));

  String write(String name, String text) {
    final file = File(p.join(folder.path, name))..writeAsStringSync(text);
    return file.path;
  }

  test('a settings file shared to the app is told apart from the media and from other JSON', () {
    final settings = SettingsFile(
      origin: const SettingsFileOrigin(appVersion: '3.4.1'),
      createdAt: DateTime.utc(2026, 11, 12),
      level: SettingsFileLevel.settings,
      content: const SettingsFileContent(settings: {'themeMode': 'dark'}),
    ).encode();

    expect(readSettingsFileAttachment(write('immuch360-settings-2026-11-12.json', settings)), settings);
    expect(readSettingsFileAttachment(write('Settings.JSON', settings)), settings, reason: 'any case');
    expect(readSettingsFileAttachment(write('map.json', '{"type": "FeatureCollection"}')), isNull);
    expect(readSettingsFileAttachment(write('photo.jpg', settings)), isNull, reason: 'a media keeps its upload');
    expect(readSettingsFileAttachment(p.join(folder.path, 'gone.json')), isNull);
  });
}
