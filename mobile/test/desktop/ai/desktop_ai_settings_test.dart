import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late DesktopAiSettingsStore store;
  File file() => File(p.join(folder.path, DesktopAiSettingsStore.fileName));

  setUp(() {
    folder = Directory.systemTemp.createTempSync('desktop_ai_settings');
    store = DesktopAiSettingsStore(settingsDirectory: () async => folder);
  });

  tearDown(() => folder.deleteSync(recursive: true));

  test('the defaults of the design without a file', () async {
    final settings = await store.read();

    expect(settings, const DesktopAiSettings());
    expect(settings.destination, AiDestination.nextToOriginal);
    expect(settings.folder, isNull);
    expect(settings.whenExists, AiWhenExists.keepBoth);
    expect(settings.skipExisting, isTrue);
    expect(settings.networkRootsAllowed, isEmpty);
    expect(settings.rootFallbacks, isEmpty);
    expect(settings.generatedAlbumState, AiGeneratedAlbumState.pending);
    expect(file().existsSync(), isFalse);
  });

  test('written then read, every field', () async {
    const settings = DesktopAiSettings(
      destination: AiDestination.folder,
      folder: r'D:\Photos 3D',
      whenExists: AiWhenExists.replace,
      skipExisting: false,
      networkRootsAllowed: ['volume:1234', r'\\nas\photos'],
      rootFallbacks: {'root:7': '/home/me/3D'},
      generatedAlbumState: AiGeneratedAlbumState.excluded,
    );

    await store.write(settings);

    expect(await DesktopAiSettingsStore(settingsDirectory: () async => folder).read(), settings);
    expect(File('${file().path}.tmp').existsSync(), isFalse);
  });

  test('keys of a newer version are kept when this one writes', () async {
    file().writeAsStringSync(jsonEncode({'whenExists': 'skip', 'futureSetting': 42}));

    await store.update((settings) => settings.copyWith(skipExisting: false));

    final kept = jsonDecode(file().readAsStringSync()) as Map<String, dynamic>;
    expect(kept['futureSetting'], 42);
    expect(kept['whenExists'], 'skip');
    expect(kept['skipExisting'], isFalse);
  });

  test('a damaged file or unknown values give the defaults, value by value', () async {
    file().writeAsStringSync('{not json');
    expect(await store.read(), const DesktopAiSettings());

    file().writeAsStringSync(
      jsonEncode({
        'destination': 'moon',
        'folder': '',
        'whenExists': 'replace',
        'skipExisting': 'yes',
        'networkRootsAllowed': ['a', 3, null],
        'rootFallbacks': {'r': '/x', 'bad': 1},
        'generatedAlbumState': 'excluded',
      }),
    );
    final settings = await store.read();

    expect(settings.destination, AiDestination.nextToOriginal);
    expect(settings.folder, isNull);
    expect(settings.whenExists, AiWhenExists.replace);
    expect(settings.skipExisting, isTrue);
    expect(settings.networkRootsAllowed, ['a']);
    expect(settings.rootFallbacks, {'r': '/x'});
    expect(settings.generatedAlbumState, AiGeneratedAlbumState.excluded);
  });

  test('changes made at once are all kept', () async {
    await Future.wait([
      store.update((settings) => settings.copyWith(networkRootsAllowed: [...settings.networkRootsAllowed, 'one'])),
      store.update((settings) => settings.copyWith(networkRootsAllowed: [...settings.networkRootsAllowed, 'two'])),
      store.update((settings) => settings.copyWith(folder: () => '/chosen')),
    ]);

    final settings = await store.read();
    expect(settings.networkRootsAllowed, ['one', 'two']);
    expect(settings.folder, '/chosen');
  });

  test('reads in turn with the writes, which Windows needs: none fails while the file is renamed over', () async {
    var round = 0;
    final reads = <Future<DesktopAiSettings>>[];
    final writes = <Future<DesktopAiSettings>>[];
    for (var i = 0; i < 40; i++) {
      writes.add(store.update((settings) => settings.copyWith(networkRootsAllowed: ['root:${round++}'])));
      reads.add(store.read());
    }

    await Future.wait([...writes, ...reads]);
    // Each read saw the write queued just before it
    for (var i = 0; i < 40; i++) {
      expect((await reads[i]).networkRootsAllowed, ['root:$i']);
    }
  });

  test('the chosen folder goes back to the download folder', () async {
    await store.write(const DesktopAiSettings(folder: '/chosen'));

    final back = await store.update((settings) => settings.copyWith(folder: () => null));

    expect(back.folder, isNull);
    expect((await store.read()).folder, isNull);
  });
}
