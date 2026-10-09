import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:path/path.dart' as p;

void main() {
  final windows = LibraryPathRules(context: p.windows, caseFold: true);
  final linux = LibraryPathRules(context: p.posix, caseFold: false);
  final ids = LibraryIds(List.filled(libraryIdKeyLength, 7));

  group('ids', () {
    test('Windows paths are normalised and case folded, so a case only rename keeps the id', () {
      expect(windows.key(r'2024\Holidays\IMG_0001.JPG'), '2024/holidays/img_0001.jpg');
      expect(windows.key(r'2024/Holidays\.\IMG_0001.JPG'), '2024/holidays/img_0001.jpg');
      expect(
        ids.file('win-1a2b3c4d:/photos', windows.key(r'2024\IMG_0001.JPG')),
        ids.file('win-1a2b3c4d:/photos', windows.key('2024/img_0001.jpg')),
      );
    });

    test('Linux keeps the case, which tells two files apart there', () {
      expect(linux.key('2024/IMG.jpg'), '2024/IMG.jpg');
      expect(ids.file('uuid-x:/p', linux.key('a.JPG')), isNot(ids.file('uuid-x:/p', linux.key('a.jpg'))));
    });

    test('an id is f and 40 hex digits, free of the path and of the account name in it', () {
      final id = ids.file(r'win-1a2b3c4d:/users/jean.dupont/pictures', windows.key('IMG_0001.JPG'));
      expect(id, matches(RegExp(r'^f[0-9a-f]{40}$')));
      expect(id, isNot(contains('jean')));
      expect(ids.album('win-1a2b3c4d:/photos', ''), matches(RegExp(r'^d[0-9a-f]{40}$')));
    });

    test('the id depends on the volume and the path inside it, not on the root it is found under', () {
      // A file of E:\Photos\2024 found from a root at E:\Photos, at E:\Photos\2024 or at E:\
      final fromPhotos = ids.file('win-1a2b3c4d:/photos', '2024/a.jpg');
      expect(ids.file('win-1a2b3c4d:/photos/2024', 'a.jpg'), fromPhotos);
      expect(ids.file('win-1a2b3c4d:/', 'photos/2024/a.jpg'), fromPhotos);
      expect(ids.album('win-1a2b3c4d:/photos', '2024'), ids.album('win-1a2b3c4d:/photos/2024', ''));
      // Another volume with the same path: another file
      expect(ids.file('win-99999999:/photos', '2024/a.jpg'), isNot(fromPhotos));
    });

    test('the id needs the key of the library: a guessed path cannot be checked against it without that key', () {
      const rootId = r'win-1a2b3c4d:/users/jean.dupont/pictures';
      final key = windows.key('IMG_0001.JPG');
      final id = ids.file(rootId, key);
      // What a plain hash of the path gives: anyone could compute it from a guessed account name and serial number
      final plain = sha256.convert(utf8.encode('$rootId/$key')).toString().substring(0, 40);
      expect(id, isNot('f$plain'));
      // Another installation, another key: the same file gets another id; the same key, the same id
      expect(LibraryIds(List.filled(libraryIdKeyLength, 8)).file(rootId, key), isNot(id));
      expect(LibraryIds(List.filled(libraryIdKeyLength, 7)).file(rootId, key), id);
      expect(() => LibraryIds(const [1, 2, 3]), throwsArgumentError);
    });

    test('nested roots', () {
      expect(rootContains('win-1:/photos', 'win-1:/photos/2024'), isTrue);
      expect(rootContains('win-1:/', 'win-1:/photos'), isTrue);
      expect(rootContains('win-1:/photos', 'win-1:/photos2'), isFalse);
      expect(rootContains('win-1:/photos', 'win-1:/photos'), isFalse);
      expect(rootContains('win-1:/photos', 'win-2:/photos/2024'), isFalse);
    });
  });

  group('what a scan takes', () {
    test('photos and videos by extension, the formats of 360° cameras included, no proxies', () {
      for (final name in ['a.jpg', 'B.JPEG', 'c.heic', 'd.insp', 'e.dng', 'f.cr3', 'g.png', 'h.webp', 'i.36p']) {
        expect(mediaKindOfName(name), LibraryMediaKind.image, reason: name);
      }
      for (final name in ['a.mp4', 'b.MOV', 'c.insv', 'd.360', 'e.osv', 'f.mkv', 'g.mts']) {
        expect(mediaKindOfName(name), LibraryMediaKind.video, reason: name);
      }
      for (final name in ['a.lrv', 'b.lrf', 'c.txt', 'd.svg', 'Thumbs.db', 'desktop.ini', 'noextension']) {
        expect(mediaKindOfName(name), isNull, reason: name);
      }
    });

    test('content types, the camera MP4s as MP4', () {
      expect(mimeTypeOfName('x.insv'), 'video/mp4');
      expect(mimeTypeOfName('x.osv'), 'video/mp4');
      expect(mimeTypeOfName('x.insp'), 'image/jpeg');
      expect(mimeTypeOfName('x.HEIC'), 'image/heic');
      expect(mimeTypeOfName('x.txt'), 'application/octet-stream');
    });

    test('folders and files skipped by name', () {
      for (final name in [r'$RECYCLE.BIN', 'System Volume Information', '.thumbnails', '@eaDir', '#recycle', '.git']) {
        expect(isSkippedFolderName(name), isTrue, reason: name);
      }
      for (final name in ['Pictures', '2024', 'DCIM', 'Camera Roll']) {
        expect(isSkippedFolderName(name), isFalse, reason: name);
      }
      expect(isSkippedFileName('._IMG_0001.JPG'), isTrue);
      expect(isSkippedFileName('IMG_0001.JPG'), isFalse);
    });
  });

  group('album names', () {
    test('the folder name, with its parents when two folders share it', () {
      final names = albumDisplayNames({
        'a': ['Pictures', 'Trips', '2024'],
        'b': ['Pictures', 'Family', '2024'],
        'c': ['Pictures', 'Screenshots'],
        'd': ['Pictures'],
        'e': ['Footage', '2024'],
      });
      expect(names, {'a': 'Trips/2024', 'b': 'Family/2024', 'c': 'Screenshots', 'd': 'Pictures', 'e': 'Footage/2024'});
    });

    test('a name still the same at the top keeps the whole path', () {
      final names = albumDisplayNames({
        'a': ['Photos', '2024'],
        'b': ['Photos', '2024'],
      });
      expect(names, {'a': 'Photos/2024', 'b': 'Photos/2024'});
    });
  });

  group('volumes', () {
    test('Windows keys: serial numbers in hex, shares by their path', () {
      expect(windowsSerialKey(0x1a2b3c4d), 'win-1a2b3c4d');
      expect(windowsSerialKey(0xab), 'win-000000ab');
      expect(windowsNetworkVolumeKey(r'\\NAS\Photos\'), 'net-//nas/photos');
      // A network drive whose share cannot be read is named by its letter
      expect(windowsNetworkVolumeKey(r'Z:\'), 'net-z:');
    });

    test('a mapped drive is reached through its share, so its folders have one id whatever the letter', () {
      expect(windowsDriveOf(r'z:\Photos'), 'Z:');
      expect(windowsDriveOf('Z:'), 'Z:');
      expect(windowsDriveOf(r'\\nas\photos'), isNull);
      expect(windowsDriveOf('Zz:'), isNull);
      expect(windowsPathThroughShare(r'Z:\2024\Trip', r'\\nas\photos'), r'\\nas\photos\2024\Trip');
      expect(windowsPathThroughShare('Z:/2024/', r'\\nas\photos\'), r'\\nas\photos\2024');
      expect(windowsPathThroughShare(r'Z:\', r'\\nas\photos'), r'\\nas\photos\');
      // The share's own key, the same as when the folder is added by its \\server\share path
      expect(windowsNetworkVolumeKey(r'\\nas\photos\'), windowsNetworkVolumeKey(r'\\NAS\Photos'));
    });

    test('a root id keeps the case only where the file system does', () {
      const identity = VolumeIdentity(
        volumeKey: 'win-1a2b3c4d',
        mountPoint: r'E:\',
        pathInVolume: '/Footage/X4',
        isNetwork: false,
      );
      expect(identity.rootId(caseFold: true), 'win-1a2b3c4d:/footage/x4');
      expect(identity.rootId(caseFold: false), 'win-1a2b3c4d:/Footage/X4');
      const top = VolumeIdentity(volumeKey: 'win-1', mountPoint: r'E:\', pathInVolume: '/', isNetwork: false);
      expect(top.rootId(caseFold: true), 'win-1:/');
    });

    group('Linux mount table', () {
      const mountInfo = '''
81 66 8:48 / / rw,relatime - ext4 /dev/sdd rw,discard
90 81 8:17 / /media/me/Footage rw,nosuid shared:5 - exfat /dev/sdb1 rw
91 81 0:50 / /mnt/nas rw - cifs //nas/photos rw,vers=3.0
92 81 0:51 / /media/me/My\\040Disk rw - vfat /dev/sdc1 rw
''';
      MountTableVolumeProbe probe(String text) => MountTableVolumeProbe(
        readMounts: () => parseMountInfo(text),
        uuidOfSource: () => const {'/dev/sdd': 'root-uuid', '/dev/sdb1': 'ABCD-1234', '/dev/sdc1': 'EF01-5678'},
      );

      test('a drive by the UUID of its file system, a share by its source, spaces unescaped', () {
        final entries = parseMountInfo(mountInfo);
        expect(entries.map((entry) => entry.mountPoint), ['/', '/media/me/Footage', '/mnt/nas', '/media/me/My Disk']);

        final footage = probe(mountInfo).identify('/media/me/Footage/X4/2024')!;
        expect(footage.volumeKey, 'uuid-ABCD-1234');
        expect(footage.pathInVolume, '/X4/2024');
        expect(footage.isNetwork, isFalse);

        final nas = probe(mountInfo).identify('/mnt/nas/2024')!;
        expect(nas.volumeKey, 'net-//nas/photos');
        expect(nas.isNetwork, isTrue);

        expect(probe(mountInfo).identify('/home/me/Pictures')!.volumeKey, 'uuid-root-uuid');
        expect(probe(mountInfo).identify('/media/me/My Disk/DCIM')!.pathInVolume, '/DCIM');
      });

      test('the same drive mounted elsewhere keeps its root id', () {
        final before = probe(mountInfo).identify('/media/me/Footage/X4')!;
        final moved = mountInfo.replaceAll('/media/me/Footage', '/run/media/me/FOOTAGE');
        final after = probe(moved).identify('/run/media/me/FOOTAGE/X4')!;
        expect(after.rootId(caseFold: false), before.rootId(caseFold: false));
      });
    });
  });
}
