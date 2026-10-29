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

  group('the settings of phases 2 and 3', () {
    test('their defaults: the 3D version of a panorama checked, no .glb copy, no integrated graphics', () async {
      final settings = await store.read();

      expect(settings.lastType, isNull);
      expect(settings.alsoStereoPanorama, isTrue);
      expect(settings.exportGlb, isFalse);
      expect(settings.componentsFolder, isNull);
      expect(settings.integratedGpuAllowed, isFalse);
      expect(settings.timings, isEmpty);
      expect(settings.comfyUiUrl, isNull);
    });

    test('written then read, every one', () async {
      const settings = DesktopAiSettings(
        lastType: 'sceneFromPhoto',
        alsoStereoPanorama: false,
        exportGlb: true,
        componentsFolder: r'D:\DEV\immuch\ai-components',
        integratedGpuAllowed: true,
        timings: {
          'sceneFromPhoto': {'geometry': 2100, 'inpaint': 900},
          'panoramaFromPhoto': {'generating': 412000},
        },
        comfyUiUrl: 'http://127.0.0.1:8188',
      );

      await store.write(settings);
      final read = await DesktopAiSettingsStore(settingsDirectory: () async => folder).read();

      expect(read, settings);
      expect(read.timings['sceneFromPhoto']!['geometry'], 2100);
      expect(read.copyWith(componentsFolder: () => null).componentsFolder, isNull);
      expect(read.copyWith(exportGlb: false), isNot(settings));
    });

    test('values that do not read give their defaults, a timing that does not read is left out', () async {
      file().writeAsStringSync(
        jsonEncode({
          'lastType': 3,
          'alsoStereoPanorama': 'no',
          'exportGlb': 1,
          'componentsFolder': '',
          'integratedGpuAllowed': null,
          'timings': {
            'sceneFromPhoto': {'geometry': 2100, 'layers': -1, 'mesh': 'fast'},
            'bad': 4,
          },
          'comfyUiUrl': '',
        }),
      );
      final settings = await store.read();

      expect(settings.lastType, isNull);
      expect(settings.alsoStereoPanorama, isTrue);
      expect(settings.exportGlb, isFalse);
      expect(settings.componentsFolder, isNull);
      expect(settings.integratedGpuAllowed, isFalse);
      expect(settings.timings, {
        'sceneFromPhoto': {'geometry': 2100},
      });
      expect(settings.comfyUiUrl, isNull);
    });
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

  group('the times of the steps', () {
    test('those of the measures of the design before any job: a scene some 25 s, a panorama at most 250 s', () {
      int total(String kind) => aiDefaultTimings[kind]!.values.fold(0, (sum, millis) => sum + millis);

      expect(const AiTimings().of('sceneFromPhoto', 'geometry'), 4500);
      expect(total('sceneFromPhoto'), inInclusiveRange(20000, 30000));
      expect(total('panoramaFromPhoto'), inInclusiveRange(200000, 260000));
      expect(total('stereoPanoramaFromPanorama'), inInclusiveRange(8000, 15000));
      expect(const AiTimings().of('sceneFromPhoto', 'rightEye'), isNull);
      expect(const AiTimings().of('lightFieldFromPhoto', 'reading'), isNull);
    });

    test('what this computer measured comes first, step by step', () {
      const timings = AiTimings({
        'sceneFromPhoto': {'geometry': 2100},
      });

      expect(timings.of('sceneFromPhoto', 'geometry'), 2100);
      expect(timings.of('sceneFromPhoto', 'inpaint'), aiDefaultTimings['sceneFromPhoto']!['inpaint']);
    });

    test('a finished job is taken in: its time the first time, then the mean with what was kept', () {
      final first = AiTimings.merged(
        const {
          'sbsFromPhoto': {'depth': 900},
        },
        'sceneFromPhoto',
        {'geometry': 3000, 'inpaint': 9000},
      );
      expect(first, {
        'sbsFromPhoto': {'depth': 900},
        'sceneFromPhoto': {'geometry': 3000, 'inpaint': 9000},
      });

      final second = AiTimings.merged(first, 'sceneFromPhoto', {'geometry': 1000, 'mesh': 400, 'layers': -5});
      expect(second['sceneFromPhoto'], {'geometry': 2000, 'inpaint': 9000, 'mesh': 400});
      expect(second['sbsFromPhoto'], {'depth': 900});
    });

    test('kept in desktop_ai.json and read back', () async {
      await store.update(
        (settings) =>
            settings.copyWith(timings: AiTimings.merged(settings.timings, 'sceneFromPhoto', {'geometry': 2500})),
      );

      expect(AiTimings((await store.read()).timings).of('sceneFromPhoto', 'geometry'), 2500);
    });
  });
}
