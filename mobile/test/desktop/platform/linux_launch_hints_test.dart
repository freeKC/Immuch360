// What a Linux computer is told or set at launch (linux_launch_hints.dart, parity lot L11): the variable of WebKitGTK's
// DMABUF renderer on an NVIDIA card (set by the launcher before any thread, told once a session), the setting's file
// in the form the launcher reads, Fedora told apart from the others by /etc/os-release, its ffmpeg-free told apart
// from the FFmpeg of RPM Fusion by the packages rpm lists, and the hint said once a session where it applies only.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/platform/linux_launch_hints.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('linux_launch_hints_test_');
    LinuxWebkitDmabuf.folder = () async => folder;
    LinuxWebkitDmabuf.forget();
    forgetWebkitDmabufDecision();
  });
  tearDown(() => folder.deleteSync(recursive: true));

  group('the DMABUF renderer of the splat viewer', () {
    test('the variable the launcher set is told once a session, on Linux only', () async {
      Future<bool> apply({bool linux = true, Map<String, String> environment = const {webkitDmabufVariable: '1'}}) =>
          applyWebkitDmabufHint(linux: linux, nvidia: () => true, environment: environment);
      expect(await apply(), isTrue);
      expect(await apply(), isFalse, reason: 'once a session');
      forgetWebkitDmabufDecision();
      expect(await apply(linux: false), isFalse);
      forgetWebkitDmabufDecision();
      expect(await apply(environment: const {}), isFalse, reason: 'nothing set: nothing set now either');
    });

    test('the file the launcher reads: {"webkitDmabufOff":false} once the setting is off', () async {
      await LinuxWebkitDmabuf.save(false);
      expect(File(p.join(folder.path, LinuxWebkitDmabuf.fileName)).readAsStringSync(), '{"webkitDmabufOff":false}');
      await LinuxWebkitDmabuf.save(true);
      expect(File(p.join(folder.path, LinuxWebkitDmabuf.fileName)).readAsStringSync(), '{"webkitDmabufOff":true}');
    });

    test('the setting: on by default, kept in its file, on again when the file is damaged', () async {
      expect(await LinuxWebkitDmabuf.load(), isTrue);
      await LinuxWebkitDmabuf.save(false);
      LinuxWebkitDmabuf.forget();
      expect(await LinuxWebkitDmabuf.load(), isFalse);
      File(p.join(folder.path, LinuxWebkitDmabuf.fileName)).writeAsStringSync('{not json');
      LinuxWebkitDmabuf.forget();
      expect(await LinuxWebkitDmabuf.load(), isTrue);
    });

    test('the NVIDIA driver by its /proc entry', () {
      final version = File(p.join(folder.path, 'version'))..writeAsStringSync('NVRM version: 550.120\n');
      expect(nvidiaDriverLoaded(path: version.path), isTrue);
      expect(nvidiaDriverLoaded(path: p.join(folder.path, 'none')), isFalse);
    });

    testWidgets('the tile of This computer turns it off and on', (tester) async {
      await tester.runAsync(() async => LinuxWebkitDmabuf.load());
      Widget app(bool shown) => EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: LinuxNvidiaSplatTile(shown: shown)),
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      final tile = find.byKey(const Key('desktop_settings_nvidia_splats'));
      // The translations and the file are read outside the fake time of the test
      for (var round = 0; round < 50 && tile.evaluate().isEmpty; round++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      // What the splat viewer reads from now on (the file itself: the test of the setting above)
      expect(await tester.runAsync(LinuxWebkitDmabuf.load), isFalse);

      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_settings_nvidia_splats')), findsNothing);
    });
  });

  group("Fedora's FFmpeg", () {
    test('Fedora and the distributions built on it, by /etc/os-release', () {
      expect(isFedoraLike('NAME="Fedora Linux"\nID=fedora\nVERSION_ID=44\n'), isTrue);
      expect(isFedoraLike('ID="nobara"\nID_LIKE="rhel centos fedora"\n'), isTrue);
      expect(isFedoraLike('ID=ubuntu\nID_LIKE=debian\n'), isFalse);
      expect(isFedoraLike('ID="rhel"\nID_LIKE="centos"\n'), isFalse);
    });

    test('ffmpeg-free alone, not with either FFmpeg of RPM Fusion', () {
      const onlyFree =
          'libavcodec-free\npackage libavcodec-freeworld is not installed\npackage ffmpeg-libs is not installed\n';
      expect(installedFfmpegPackages(onlyFree), {'libavcodec-free'});
      expect(onlyFfmpegFree(installedFfmpegPackages(onlyFree)), isTrue);
      expect(onlyFfmpegFree({'libavcodec-free', 'libavcodec-freeworld'}), isFalse);
      expect(onlyFfmpegFree({'ffmpeg-libs'}), isFalse);
      expect(onlyFfmpegFree(const {}), isFalse);
    });

    test('asked of rpm on Fedora only', () async {
      final fedora = File(p.join(folder.path, 'fedora'))..writeAsStringSync('ID=fedora\n');
      final ubuntu = File(p.join(folder.path, 'ubuntu'))..writeAsStringSync('ID=ubuntu\n');
      final asked = <List<String>>[];
      Future<String?> rpm(String program, List<String> arguments) async {
        asked.add([program, ...arguments]);
        return 'libavcodec-free\n';
      }

      expect(await usesFedoraFfmpegFree(linux: true, osReleasePath: fedora.path, run: rpm), isTrue);
      expect(asked.single.take(2), ['rpm', '-q']);
      expect(asked.single, containsAll(ffmpegPackages));
      expect(await usesFedoraFfmpegFree(linux: true, osReleasePath: ubuntu.path, run: rpm), isFalse);
      expect(await usesFedoraFfmpegFree(linux: false, osReleasePath: fedora.path, run: rpm), isFalse);
      expect(await usesFedoraFfmpegFree(linux: true, osReleasePath: p.join(folder.path, 'none'), run: rpm), isFalse);
      expect(
        await usesFedoraFfmpegFree(linux: true, osReleasePath: fedora.path, run: (_, _) async => null),
        isFalse,
        reason: 'no rpm',
      );
      expect(asked, hasLength(1), reason: 'rpm is asked on Fedora only');
    });

    test('the hint is said once a session, where it applies only', () async {
      final shown = <String>[];
      final hint = FedoraFfmpegHint(detect: () async => true, show: shown.add);
      await hint.playbackFailed();
      await hint.playbackFailed();
      expect(shown, hasLength(1));
      expect(shown.single, isNotEmpty);

      var detections = 0;
      final elsewhere = FedoraFfmpegHint(
        detect: () async {
          detections++;
          return false;
        },
        show: shown.add,
      );
      await elsewhere.playbackFailed();
      await elsewhere.playbackFailed();
      expect(shown, hasLength(1));
      expect(detections, 1, reason: 'rpm is asked once');
    });
  });
}
