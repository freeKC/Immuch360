import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_immersive_engine.dart';
import '../fakes/recording_creator_files.dart';
import 'english_texts.dart';

/// The volumes as the tests decide them: local unless named here, every question written down
class _Volumes implements FolderVolumes {
  final network = <String, FolderVolume>{};
  final networkMounts = <String>{};
  final unreadable = <String>{};
  final asked = <String>[];

  @override
  FolderVolume? of(String folder) {
    asked.add(folder);
    if (unreadable.contains(folder)) {
      return null;
    }
    return network[folder] ??
        FolderVolume(
          volumeKey: 'uuid-local',
          folderKey: 'uuid-local:/${folder.replaceAll(r'\', '/').replaceFirst(RegExp('^/'), '')}',
          mountPoint: '/',
          isNetwork: false,
        );
  }

  @override
  bool isNetworkMount(String folder) => networkMounts.contains(folder);
}

/// A volume probe that counts its questions
class _CountingProbe extends VolumeProbe {
  final identified = <String>[];

  @override
  VolumeIdentity? identify(String absolutePath) {
    identified.add(absolutePath);
    return VolumeIdentity(volumeKey: 'uuid-1', mountPoint: '/', pathInVolume: absolutePath, isNetwork: false);
  }

  @override
  String? locate(String volumeKey, String pathInVolume) => null;
}

/// Makes [folder] refuse new files: chmod on Linux and macOS, a read only ACL on Windows. False when it cannot.
bool _lock(Directory folder) {
  final result = Platform.isWindows
      ? Process.runSync('icacls', [folder.path, '/deny', '*S-1-1-0:(WD,AD)'])
      : Process.runSync('chmod', ['555', folder.path]);
  return result.exitCode == 0;
}

void _unlock(Directory folder) {
  if (Platform.isWindows) {
    Process.runSync('icacls', [folder.path, '/remove:d', '*S-1-1-0']);
  } else {
    Process.runSync('chmod', ['755', folder.path]);
  }
}

void main() {
  late Directory root;
  late Directory support;
  late String downloads;
  late RecordingCreatorFiles files;
  late SafeWriter writer;
  late _Volumes volumes;

  DesktopAiSettingsStore store() => DesktopAiSettingsStore(settingsDirectory: () async => support);
  Future<List<String>> noted() => InflightJournal(settingsDirectory: () async => support).paths();
  Directory folder(String relative) => Directory(p.join(root.path, relative))..createSync(recursive: true);
  File photo(Directory folder, String name) =>
      File(p.join(folder.path, name))..writeAsBytesSync([0xff, 0xd8, 1, 2, 0xff, 0xd9]);
  List<String> partsIn(String folder) => Directory(folder).existsSync()
      ? [
          for (final entity in Directory(folder).listSync())
            if (isPartFileName(p.basename(entity.path))) entity.path,
        ]
      : const [];
  DestinationSession session(List<DestinationJob> jobs) =>
      DestinationSession(jobs, store: store(), writer: writer, volumes: volumes, downloadFolder: () async => downloads);
  DestinationPlanner planner([DesktopAiSettings settings = const DesktopAiSettings()]) =>
      DestinationPlanner(settings: settings, chosenFolder: downloads, volumes: volumes);
  LibraryOriginal local(Directory folder, String name, {String rootId = 'uuid-1234:/photos', bool cloudOnly = false}) =>
      LibraryOriginal(
        name: name,
        path: p.join(folder.path, name),
        rootId: rootId,
        rootPath: folder.path,
        rootIsNetwork: false,
        cloudOnly: cloudOnly,
      );
  LibraryOriginal onNas(Directory folder, String name) => LibraryOriginal(
    name: name,
    path: p.join(folder.path, name),
    rootId: 'net-//nas/photos:/2024',
    rootPath: folder.path,
    rootIsNetwork: true,
  );

  setUp(() {
    loadEnglishTexts();
    root = Directory.systemTemp.createTempSync('ai_destination');
    support = Directory(p.join(root.path, 'support'))..createSync();
    downloads = p.join(root.path, 'Downloads', 'Immuch360');
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
    );
    volumes = _Volumes();
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('the plan, source by source (design 2.5)', () {
    test('a folder of the library on a local disk: next to the original', () {
      final photos = folder('Photos');

      final plan = planner().plan(local(photos, 'salon.jpg'));

      expect(plan.kind, DestinationKind.nextToOriginal);
      expect(plan.folder, photos.path);
      expect(plan.isNetwork, isFalse);
      expect(plan.waitsForConsent, isFalse);
      expect(plan.reason, isNull);
      expect(plan.rootKey, 'uuid-1234:/photos');
    });

    test('a refusal kept for its root: the folder kept, with its reason, and the folder of the original untouched', () {
      final photos = folder('Photos');
      final kept = p.join(root.path, 'Elsewhere');

      final plan = planner(
        DesktopAiSettings(rootFallbacks: {'uuid-1234:/photos': kept}),
      ).plan(local(photos, 'salon.jpg', rootId: 'uuid-1234:/photos/2024'));

      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, kept);
      expect(plan.reason, DestinationReason.folderReadOnly);
      expect(plan.rootKey, 'uuid-1234:/photos/2024');
      expect(volumes.asked, isNot(contains(photos.path)));
    });

    test('a network folder of the library: next to the original after a yes for that root', () {
      final nas = folder('nas');

      final waiting = planner().plan(onNas(nas, 'salon.jpg'));
      final allowed = planner(
        const DesktopAiSettings(networkRootsAllowed: ['net-//nas/photos:/2024']),
      ).plan(onNas(nas, 'salon.jpg'));
      final volumeAllowed = planner(
        const DesktopAiSettings(networkRootsAllowed: ['net-//nas/photos']),
      ).plan(onNas(nas, 'salon.jpg'));
      final otherAllowed = planner(
        const DesktopAiSettings(networkRootsAllowed: ['net-//nas/photos:/2023']),
      ).plan(onNas(nas, 'salon.jpg'));

      expect(waiting.kind, DestinationKind.nextToOriginal);
      expect(waiting.isNetwork, isTrue);
      expect(waiting.waitsForConsent, isTrue);
      expect(waiting.consentKey, 'net-//nas/photos:/2024');
      expect(waiting.consentFolder, nas.path);
      expect(allowed.waitsForConsent, isFalse);
      expect(allowed.folder, nas.path);
      expect(volumeAllowed.waitsForConsent, isFalse);
      expect(otherAllowed.waitsForConsent, isTrue);
    });

    test('macOS: a root on a network mount the library does not mark waits for the yes too', () {
      final nas = folder('Volumes/photos');
      volumes.networkMounts.add(nas.path);

      final plan = planner().plan(local(nas, 'salon.jpg', rootId: 'mnt-/Volumes/photos:/'));

      expect(plan.isNetwork, isTrue);
      expect(plan.consentKey, 'mnt-/Volumes/photos:/');
    });

    test('a file kept online only: next to the original, and the dialog says reading it downloads it', () {
      final photos = folder('OneDrive');

      final plan = planner().plan(local(photos, 'salon.jpg', cloudOnly: true));

      expect(plan.kind, DestinationKind.nextToOriginal);
      expect(plan.cloudDownload, isTrue);
    });

    test('a file opened with the program: next to it on a local volume, after a yes for its volume on the network', () {
      final desk = folder('Desktop');
      final share = folder('share');
      volumes.network[share.path] = FolderVolume(
        volumeKey: 'net-//nas/photos',
        folderKey: 'net-//nas/photos:/2024',
        mountPoint: share.path,
        isNetwork: true,
      );

      final onDesk = planner().plan(OpenedOriginal(name: 'a.jpg', path: p.join(desk.path, 'a.jpg')));
      final onShare = planner().plan(OpenedOriginal(name: 'b.jpg', path: p.join(share.path, 'b.jpg')));
      final rootAllowed = planner(
        const DesktopAiSettings(networkRootsAllowed: ['net-//nas/photos:/2024']),
      ).plan(OpenedOriginal(name: 'b.jpg', path: p.join(share.path, 'b.jpg')));

      expect(onDesk.kind, DestinationKind.nextToOriginal);
      expect(onDesk.folder, desk.path);
      expect(onDesk.waitsForConsent, isFalse);
      expect(onShare.kind, DestinationKind.nextToOriginal);
      expect(onShare.consentKey, 'net-//nas/photos');
      expect(onShare.consentFolder, share.path);
      expect(onShare.isNetwork, isTrue);
      expect(rootAllowed.waitsForConsent, isFalse);
    });

    test('a file opened from a volume that cannot be read: the chosen folder', () {
      final gone = p.join(root.path, 'Gone');
      volumes.unreadable.add(gone);

      final plan = planner().plan(OpenedOriginal(name: 'a.jpg', path: p.join(gone, 'a.jpg')));

      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.folderMissing);
    });

    test('a share opened in the app: the download folder, never the share, with the tip', () {
      final plan = planner().plan(const ShareOriginal(name: 'salon.jpg'));

      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.sourceReadOnly);
      expect(plan.shareHint, isTrue);
    });

    test('DLNA, Plex, the Immich server: the download folder, never the source', () {
      final plan = planner().plan(const ServerOriginal(name: 'salon.jpg'));

      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.sourceReadOnly);
      expect(plan.shareHint, isFalse);
    });

    test('the settings say a folder of my choice: every photo goes there, without a reason to show', () {
      final photos = folder('Photos');
      final mine = p.join(root.path, '3D');
      const settings = DesktopAiSettings(destination: AiDestination.folder);

      final plan = DestinationPlanner(
        settings: settings.copyWith(folder: () => mine),
        chosenFolder: mine,
        volumes: volumes,
      ).plan(local(photos, 'salon.jpg'));
      final opened = DestinationPlanner(
        settings: settings,
        chosenFolder: downloads,
        volumes: volumes,
      ).plan(OpenedOriginal(name: 'a.jpg', path: p.join(photos.path, 'a.jpg')));

      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, mine);
      expect(plan.reason, isNull);
      expect(opened.folder, downloads);
    });

    test('a chosen folder on the network is no "this computer only" destination', () {
      final nasFolder = p.join(root.path, 'Z');
      volumes.network[nasFolder] = FolderVolume(
        volumeKey: 'net-z:',
        folderKey: 'net-z:/',
        mountPoint: nasFolder,
        isNetwork: true,
      );

      final plan = DestinationPlanner(
        settings: const DesktopAiSettings(),
        chosenFolder: nasFolder,
        volumes: volumes,
      ).plan(const ServerOriginal(name: 'a.jpg'));

      expect(plan.isNetwork, isTrue);
      expect(planner().plan(const ServerOriginal(name: 'a.jpg')).isNetwork, isFalse);
    });
  });

  group('the mount table of macOS', () {
    const output = '''
/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
devfs on /dev (devfs, local, nobrowse)
/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect)
map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
//me@nas._smb._tcp.local/photos on /Volumes/photos (smbfs, nodev, nosuid, mounted by me)
nas:/export/videos on /Volumes/My Videos (nfs, nodev, nosuid, mounted by me)
/dev/disk4s2 on /Volumes/Card (msdos, local, nodev, nosuid, noowners)
''';

    test('the shares are told from the local disks', () {
      final mounts = parseMacMounts(output);

      expect(mounts.map((mount) => mount.mountPoint), [
        '/',
        '/dev',
        '/System/Volumes/Data',
        '/Volumes/photos',
        '/Volumes/My Videos',
        '/Volumes/Card',
      ]);
      expect(isOnNetworkMount(mounts, '/Volumes/photos/2024'), isTrue);
      expect(isOnNetworkMount(mounts, '/volumes/Photos'), isTrue);
      expect(isOnNetworkMount(mounts, '/Volumes/My Videos/clips'), isTrue);
      expect(isOnNetworkMount(mounts, '/Volumes/Card/DCIM'), isFalse);
      expect(isOnNetworkMount(mounts, '/Users/me/Pictures'), isFalse);
      expect(isOnNetworkMount(mounts, '/Volumes/photos2'), isFalse);
      expect(isOnNetworkMount(const [], '/Volumes/photos'), isFalse);
    });

    test('the volume of a folder is read once per dialog', () {
      final probe = _CountingProbe();
      final system = SystemFolderVolumes(probe: probe, macOS: false);

      final first = system.of('/home/me/Pictures');
      final again = system.of('/home/me/Pictures');
      system.of('/home/me/Videos');

      expect(again, same(first));
      expect(first!.folderKey, startsWith('uuid-1:/'));
      expect(probe.identified, ['/home/me/Pictures', '/home/me/Videos']);
    });

    test('a file opened from a NAS, or a folder chosen on it, is on the network, whatever its mount point', () {
      final macRules = LibraryPathRules(context: p.posix, caseFold: true);
      final mac = SystemFolderVolumes(
        macOS: true,
        probe: const MountPathVolumeProbe(),
        rules: macRules,
        readMacMounts: () =>
            '$output'
            'nas:/export/photos on /net/nas/photos (nfs, nodev, nosuid, automounted, nobrowse)\n'
            'nas2:/export/videos on /net/nas2/videos (nfs, nodev, nosuid, automounted, nobrowse)\n',
      );

      final volumes = mac.of('/Volumes/photos/2024')!;
      final automounted = mac.of('/net/nas/photos/2024')!;
      final boot = mac.of('/Users/me/Pictures')!;
      final card = mac.of('/Volumes/Card/DCIM')!;

      expect(volumes.isNetwork, isTrue);
      expect(volumes.volumeKey, 'mnt-/Volumes/photos');
      expect(volumes.mountPoint, '/Volumes/photos');
      expect(volumes.folderKey, 'mnt-/Volumes/photos:/2024');
      expect(automounted.isNetwork, isTrue);
      expect(automounted.volumeKey, 'mnt-/net/nas/photos');
      expect(automounted.mountPoint, '/net/nas/photos');
      expect(automounted.folderKey, 'mnt-/net/nas/photos:/2024');
      expect(boot.isNetwork, isFalse);
      expect(boot.volumeKey, 'mnt-/');
      expect(card.isNetwork, isFalse);

      // The question names the NAS, and its yes covers the NAS alone, never the boot disk
      final planner = DestinationPlanner(
        settings: const DesktopAiSettings(),
        chosenFolder: '/Users/me/Downloads/Immuch360',
        volumes: mac,
        rules: macRules,
      );
      final opened = planner.plan(const OpenedOriginal(name: 'a.jpg', path: '/net/nas/photos/2024/a.jpg'));
      expect(opened.waitsForConsent, isTrue);
      expect(opened.consentKey, 'mnt-/net/nas/photos');
      expect(opened.consentFolder, '/net/nas/photos');
      final allowed = DestinationPlanner(
        settings: const DesktopAiSettings(networkRootsAllowed: ['mnt-/net/nas/photos']),
        chosenFolder: '/Users/me/Downloads/Immuch360',
        volumes: mac,
        rules: macRules,
      );
      expect(
        allowed.plan(const OpenedOriginal(name: 'a.jpg', path: '/net/nas/photos/2024/a.jpg')).waitsForConsent,
        isFalse,
      );
      expect(allowed.plan(const OpenedOriginal(name: 'b.jpg', path: '/Volumes/photos/b.jpg')).waitsForConsent, isTrue);
      expect(allowed.plan(const OpenedOriginal(name: 'c.jpg', path: '/net/nas2/videos/c.jpg')).waitsForConsent, isTrue);
      expect(allowed.plan(const OpenedOriginal(name: 'd.jpg', path: '/Users/me/d.jpg')).waitsForConsent, isFalse);
      expect(planner.plan(const ServerOriginal(name: 'c.jpg')).isNetwork, isFalse);
      expect(
        DestinationPlanner(
          settings: const DesktopAiSettings(),
          chosenFolder: '/Volumes/photos/3D',
          volumes: mac,
          rules: macRules,
        ).plan(const ServerOriginal(name: 'c.jpg')).isNetwork,
        isTrue,
      );
    });

    test('read once, and only on macOS', () {
      var reads = 0;
      String read() {
        reads++;
        return output;
      }

      final mac = SystemFolderVolumes(macOS: true, readMacMounts: read);
      final other = SystemFolderVolumes(macOS: false, readMacMounts: read);

      expect(mac.isNetworkMount('/Volumes/photos/a'), isTrue);
      expect(mac.isNetworkMount('/Users/me'), isFalse);
      expect(other.isNetworkMount('/Volumes/photos/a'), isFalse);
      expect(reads, 1);
    });
  });

  group('the dialog', () {
    test('a network folder without the yes: nothing is written nor tried there', () async {
      final nas = folder('nas');
      final original = photo(nas, 'salon.jpg');
      final dialog = session([DestinationJob(id: 'j1', original: onNas(nas, 'salon.jpg'))]);

      await dialog.open();

      expect(dialog.pendingConsents, {'net-//nas/photos:/2024': nas.path});
      expect(dialog.destinations['j1']!.waitsForConsent, isTrue);
      expect(dialog.checkOf('j1'), isNull);
      expect(files.callsUnder(nas.path), isEmpty);
      expect(volumes.asked, isNot(contains(nas.path)));
      expect(dialog.takePart('j1'), isNull);
      await dialog.close();
      expect(files.callsUnder(nas.path), isEmpty);
      expect(nas.listSync().map((entity) => entity.path), [original.path]);
    });

    test('"Yes, for this network folder": kept, then the folder is checked by the partial file of its job', () async {
      final nas = folder('nas');
      photo(nas, 'salon.jpg');
      final dialog = session([DestinationJob(id: 'j1', original: onNas(nas, 'salon.jpg'))]);
      await dialog.open();

      await dialog.allowNetwork('net-//nas/photos:/2024');

      expect(dialog.pendingConsents, isEmpty);
      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      expect(partsIn(nas.path), hasLength(1));
      expect((await store().read()).networkRootsAllowed, ['net-//nas/photos:/2024']);
      expect(dialog.takePart('j1')!.path, partsIn(nas.path).single);
      await dialog.close();

      // The next dialog does not ask again
      final next = session([DestinationJob(id: 'j2', original: onNas(nas, 'salon.jpg'))]);
      await next.open();
      expect(next.pendingConsents, isEmpty);
      expect(next.destinations['j2']!.kind, DestinationKind.nextToOriginal);
      await next.close();
    });

    test('"No, choose a folder": the chosen folder, and still nothing tried in the network folder', () async {
      final nas = folder('nas');
      photo(nas, 'salon.jpg');
      final dialog = session([DestinationJob(id: 'j1', original: onNas(nas, 'salon.jpg'))]);
      await dialog.open();

      await dialog.declineNetwork('net-//nas/photos:/2024');

      final plan = dialog.destinations['j1']!;
      expect(plan.kind, DestinationKind.chosenFolder);
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.networkDeclined);
      expect(dialog.pendingConsents, isEmpty);
      expect(partsIn(downloads), hasLength(1));
      expect(files.callsUnder(nas.path), isEmpty);
      expect((await store().read()).networkRootsAllowed, isEmpty);
      await dialog.close();
    });

    test('a file opened from the network: the yes is given for its volume', () async {
      final share = folder('share');
      photo(share, 'b.jpg');
      volumes.network[share.path] = FolderVolume(
        volumeKey: 'net-//nas/photos',
        folderKey: 'net-//nas/photos:/2024',
        mountPoint: share.path,
        isNetwork: true,
      );
      final dialog = session([
        DestinationJob(
          id: 'j1',
          original: OpenedOriginal(name: 'b.jpg', path: p.join(share.path, 'b.jpg')),
        ),
      ]);
      await dialog.open();
      expect(dialog.pendingConsents.keys, ['net-//nas/photos']);
      expect(files.callsUnder(share.path), isEmpty);

      await dialog.allowNetwork('net-//nas/photos');

      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      expect((await store().read()).networkRootsAllowed, ['net-//nas/photos']);
      await dialog.close();
    });

    test('a local folder is checked when the dialog opens; the job takes the partial file and ends there', () async {
      final photos = folder('Photos');
      final original = photo(photos, 'salon.jpg')..setLastModifiedSync(DateTime(2024, 5, 17, 9, 30));
      final bytes = original.readAsBytesSync();
      final modified = original.lastModifiedSync();
      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'salon.jpg'))]);

      await dialog.open();
      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      final probed = partsIn(photos.path).single;

      final part = dialog.takePart('j1')!;
      await dialog.close();
      expect(part.path, probed);
      expect(File(probed).existsSync(), isTrue);

      final engine = FakeImmersiveEngine();
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      final source = ImmersiveSource(name: 'salon.jpg', size: bytes.length, sha1: 'c2hhMQ==', path: original.path);
      final result = await engine.run(
        ImmersiveJob(
          id: 'j1',
          source: source,
          partPath: part.path,
          derivativeId: StereoPhotoXmp.newDerivativeId(),
          creatorTool: 'Immuch360 Desktop (test)',
          created: '2026-10-27T10:12:00+01:00',
        ),
        cancel: cancel,
      );
      expect(result.isDone, isTrue);
      final saved = await writer.commit(part, original: OriginalIdentity.of(source));
      await engine.dispose();

      expect(saved.path, p.join(photos.path, 'salon_3D_LRF_Full_SBS.jpg'));
      expect(StereoPhotoXmp.findIn(File(saved.path).readAsBytesSync())?.sourceName, 'salon.jpg');
      expect(partsIn(photos.path), isEmpty);
      expect(await noted(), isEmpty);
      expect(original.readAsBytesSync(), bytes);
      expect(original.lastModifiedSync(), modified);
    });

    test('closed without launching: every partial file of the check is deleted', () async {
      final photos = folder('Photos');
      final other = folder('Other');
      photo(photos, 'a.jpg');
      photo(other, 'b.jpg');
      final dialog = session([
        DestinationJob(id: 'j1', original: local(photos, 'a.jpg')),
        DestinationJob(
          id: 'j2',
          original: local(other, 'b.jpg', rootId: 'uuid-1234:/other'),
        ),
        const DestinationJob(
          id: 'j3',
          original: ServerOriginal(name: 'c.jpg'),
        ),
      ]);
      await dialog.open();
      expect(partsIn(photos.path), hasLength(1));
      expect(partsIn(other.path), hasLength(1));
      expect(partsIn(downloads), hasLength(1));

      await dialog.close();

      expect(partsIn(photos.path), isEmpty);
      expect(partsIn(other.path), isEmpty);
      expect(partsIn(downloads), isEmpty);
      expect(await noted(), isEmpty);
    });

    test('one partial file per folder, whatever the number of photos in it', () async {
      final photos = folder('Photos');
      final dialog = session([
        for (var index = 0; index < 5; index++) DestinationJob(id: 'j$index', original: local(photos, 'p$index.jpg')),
      ]);

      await dialog.open();

      expect(partsIn(photos.path), hasLength(1));
      expect(dialog.takePart('j0'), isNotNull);
      expect(dialog.takePart('j1'), isNull);
      await dialog.close();
    });

    test(
      'a folder of the library that refuses new files: the chosen folder, with its reason, kept for the root',
      () async {
        final locked = folder('Locked');
        final original = photo(locked, 'salon.jpg');
        if (!_lock(locked)) {
          markTestSkipped('The rights of the folder cannot be changed here');
          return;
        }
        addTearDown(() => _unlock(locked));
        try {
          File(p.join(locked.path, '.rights')).createSync(exclusive: true);
          File(p.join(locked.path, '.rights')).deleteSync();
          markTestSkipped('The tests run with rights that write in every folder');
          return;
        } on FileSystemException {
          // As expected: the folder refuses new files
        }
        final dialog = session([DestinationJob(id: 'j1', original: local(locked, 'salon.jpg'))]);

        await dialog.open();

        final plan = dialog.destinations['j1']!;
        expect(plan.kind, DestinationKind.chosenFolder);
        expect(plan.folder, downloads);
        expect(plan.reason, DestinationReason.folderReadOnly);
        expect(
          destinationReasonText(StaticTranslations.instance, plan.reason),
          'This folder does not accept new files',
        );
        expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
        expect(partsIn(downloads), hasLength(1));
        expect((await store().read()).rootFallbacks, {'uuid-1234:/photos': downloads});
        expect(locked.listSync().map((entity) => entity.path), [original.path]);
        await dialog.close();

        // The next dialog goes to the folder kept at once, without trying the locked one again
        files.calls.clear();
        final next = session([DestinationJob(id: 'j2', original: local(locked, 'salon.jpg'))]);
        await next.open();
        expect(next.destinations['j2']!.folder, downloads);
        expect(next.destinations['j2']!.reason, DestinationReason.folderReadOnly);
        expect(files.callsUnder(locked.path), isEmpty);
        await next.close();
      },
    );

    test('"Change": the photos of the chosen folder go to the new one, kept for the root that refused', () async {
      final photos = folder('Photos');
      files.failures[photos.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);
      final mine = p.join(root.path, 'Mine');
      final dialog = session([
        DestinationJob(id: 'j1', original: local(photos, 'a.jpg')),
        const DestinationJob(
          id: 'j2',
          original: ServerOriginal(name: 'b.jpg'),
        ),
      ]);
      await dialog.open();
      expect(partsIn(downloads), hasLength(1));

      await dialog.chooseFolder(mine);

      expect(dialog.destinations.values.map((plan) => plan.folder), everyElement(mine));
      expect(partsIn(downloads), isEmpty);
      expect(partsIn(mine), hasLength(1));
      expect((await store().read()).rootFallbacks, {'uuid-1234:/photos': mine});
      await dialog.close();
      expect(partsIn(mine), isEmpty);
    });

    test('"Next to the original" again: the refusal kept is forgotten and the folder checked again', () async {
      final photos = folder('Photos');
      files.failures[photos.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);
      final first = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);
      await first.open();
      await first.close();
      expect((await store().read()).rootFallbacks, isNotEmpty);
      files.failures.clear();

      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);
      await dialog.open();
      expect(dialog.destinations['j1']!.kind, DestinationKind.chosenFolder);
      await dialog.saveTo(AiDestination.nextToOriginal);

      expect(dialog.destinations['j1']!.kind, DestinationKind.nextToOriginal);
      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      expect(partsIn(photos.path), hasLength(1));
      expect(partsIn(downloads), isEmpty);
      expect((await store().read()).rootFallbacks, isEmpty);
      await dialog.close();
    });

    test('"Next to the original" in the dialog where the folder refused: checked again at once', () async {
      final photos = folder('Photos');
      files.failures[photos.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);
      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);
      await dialog.open();
      expect(dialog.destinations['j1']!.kind, DestinationKind.chosenFolder);
      expect((await store().read()).rootFallbacks, isNotEmpty);
      files.failures.clear();

      await dialog.saveTo(AiDestination.nextToOriginal);

      expect(dialog.destinations['j1']!.kind, DestinationKind.nextToOriginal);
      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      expect(partsIn(photos.path), hasLength(1));
      expect(partsIn(downloads), isEmpty);
      expect((await store().read()).rootFallbacks, isEmpty);
      await dialog.close();
    });

    test('a folder that failed otherwise: the chosen folder, and the words of the system kept', () async {
      final photos = folder('Photos');
      files.failures[photos.path] = OSError('Input/output error', Platform.isWindows ? 1117 : 5);
      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);

      await dialog.open();

      final plan = dialog.destinations['j1']!;
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.writeFailed);
      expect(plan.message, 'Write refused: Input/output error');
      expect(
        destinationReasonText(StaticTranslations.instance, plan.reason, message: plan.message),
        'The 3D photo could not be written: Write refused: Input/output error',
      );
      expect(dialog.checkOf('j1')!.status, ProbeStatus.ready);
      expect((await store().read()).rootFallbacks, isEmpty);
      await dialog.close();
    });

    test('a journal that cannot be written is never kept against the folder of the original', () async {
      final photos = folder('Photos');
      writer = SafeWriter(files: files, journal: _FailingJournal(support));
      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);

      await dialog.open();

      final plan = dialog.destinations['j1']!;
      expect(plan.reason, DestinationReason.writeFailed);
      expect(plan.message, contains('partial files'));
      expect((await store().read()).rootFallbacks, isEmpty);
      expect(files.calls.where((call) => call.startsWith('createNew')), isEmpty);
      await dialog.close();
    });

    test('a full disk next to the original: the chosen folder with "Disk full", not kept for the root', () async {
      final photos = folder('Photos');
      files.failures[photos.path] = OSError('No space left', Platform.isWindows ? 112 : 28);
      final dialog = session([DestinationJob(id: 'j1', original: local(photos, 'a.jpg'))]);

      await dialog.open();

      final plan = dialog.destinations['j1']!;
      expect(plan.folder, downloads);
      expect(plan.reason, DestinationReason.diskFull);
      expect(destinationReasonText(StaticTranslations.instance, plan.reason), 'Disk full');
      expect((await store().read()).rootFallbacks, isEmpty);
      await dialog.close();
    });
  });

  test('the reasons the dialog shows', () {
    final t = StaticTranslations.instance;

    expect(destinationReasonText(t, null), isNull);
    expect(destinationReasonText(t, DestinationReason.networkDeclined), isNull);
    expect(
      destinationReasonText(t, DestinationReason.sourceReadOnly),
      'This source cannot be written to: choose a folder',
    );
    expect(destinationReasonText(t, DestinationReason.folderReadOnly), 'This folder does not accept new files');
    expect(destinationReasonText(t, DestinationReason.diskFull), 'Disk full');
    expect(destinationReasonText(t, DestinationReason.folderMissing), 'The original cannot be reached any more');
    expect(
      destinationReasonText(t, DestinationReason.writeFailed, message: 'I/O error'),
      'The 3D photo could not be written: I/O error',
    );
  });
}

/// A journal whose support folder is full
class _FailingJournal extends InflightJournal {
  _FailingJournal(Directory support) : super(settingsDirectory: () async => support);

  @override
  Future<void> add(String path) async => throw FileSystemException(
    'Cannot write the journal',
    p.join('support', InflightJournal.fileName),
    OSError('No space left on device', Platform.isWindows ? 112 : 28),
  );
}
