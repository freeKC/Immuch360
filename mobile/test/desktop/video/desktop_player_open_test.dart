// DesktopPlayer.open hands the address to mpv itself (loadfile), never through media_kit's open, which writes what it
// plays to a list file in the temporary folder and deletes it five seconds later (TempFile in its real.dart): a URL of
// the media bridge holds the bridge's token, a live address the camera account. Under DesktopPlayer, media_kit's
// PlatformPlayer (libmpv's place) is faked: its open writes that list file the way media_kit's does, so a DesktopPlayer
// that went back to it fails here. The temporary folder is Dart's Directory.systemTemp, the %TEMP% of Windows.
//
// The check looks at the top level of that folder only (media_kit's list file is Directory.systemTemp/<uuid v4>) and
// reads only the regular files that appeared or changed during the open: a machine's temporary folder may hold tens of
// thousands of files, and on Linux named pipes that Directory.list gives as files and whose read waits for a writer
// forever (the 30 second timeouts of these tests on the Ubuntu CI).
//
// With the libmpv of a Windows build, desktop_player_windows_test.dart watches %TEMP% from the open to the first frame.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _token = 'BridgeToken7f3a9c51e2';
const _bridgeUrl = 'http://127.0.0.1:52011/$_token/smb-nas/Videos/clip.mp4';
const _liveAddress = 'rtsp://camuser:CamPassword42@192.168.1.20:554/stream2';

Stream<T> _none<T>() => Stream<T>.empty();

/// media_kit's player without libmpv: records what DesktopPlayer asks of it, in order
class _FakeNativePlayer extends Fake implements NativePlayer {
  _FakeNativePlayer(this.listFiles);

  /// The list files its open wrote, as media_kit's open does
  final List<File> listFiles;

  final calls = <String>[];
  final commands = <List<String>>[];
  final properties = <String, String>{};
  var opens = 0;

  @override
  final List<Future<void> Function()> onLoadHooks = [];

  @override
  final List<Future<void> Function()> onUnloadHooks = [];

  @override
  final PlayerStream stream = PlayerStream(
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
    _none(),
  );

  @override
  Future<void> setProperty(String property, String value, {bool waitForInitialization = true}) async {
    calls.add('set $property=$value');
    properties[property] = value;
  }

  @override
  Future<void> command(List<String> command, {bool waitForInitialization = true}) async {
    calls.add(command.join(' '));
    commands.add(command);
  }

  @override
  Future<void> observeEvent(
    int event,
    Future<void> Function(Pointer<mpv.mpv_event>) listener, {
    bool waitForInitialization = true,
  }) async {}

  @override
  Future<void> stop({bool open = false, bool notify = true, bool synchronized = true}) async {
    calls.add('stop');
  }

  /// What media_kit's open does with a Media (real.dart and TempFile): every address in a list file of the temporary
  /// folder named by a v4 UUID, for mpv's loadlist
  @override
  Future<void> open(Playable playable, {bool play = true, bool synchronized = true}) async {
    calls.add('open');
    opens++;
    final medias = playable is Media ? [playable] : (playable as Playlist).medias;
    final file = File(p.join(Directory.systemTemp.path, const Uuid().v4()));
    await file.writeAsString(medias.map((media) => '${media.uri}\n').join());
    listFiles.add(file);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {}

  /// mpv loading the file: the on_load hooks, as media_kit runs them
  Future<void> load() async {
    for (final hook in onLoadHooks) {
      await hook();
    }
  }
}

/// Every file made in the zone it watches, whatever the folder: DesktopPlayer.open makes none
final class _FileWatch extends IOOverrides {
  final paths = <String>[];

  @override
  File createFile(String path) {
    paths.add(path);
    return super.createFile(path);
  }
}

/// The entries of the top level of the temporary folder that are files, with their state: names and metadata only,
/// nothing below that level and no file opened
Map<String, FileStat> _tempTopLevel() => {
  for (final entity in Directory.systemTemp.listSync(followLinks: false))
    if (entity is File) entity.path: entity.statSync(),
};

/// The names of the regular files of the top level of the temporary folder that appeared or changed since [before]
/// (taken by [_tempTopLevel] as the test started) and hold [secret]: only those are read
List<String> _tempFilesHolding(String secret, Map<String, FileStat> before) {
  final found = <String>[];
  for (final MapEntry(key: path, value: stat) in _tempTopLevel().entries) {
    final earlier = before[path];
    final changed = earlier == null || earlier.modified != stat.modified || earlier.size != stat.size;
    // A named pipe or a socket is listed as a file too: a read of a pipe waits for a writer. A list file holds a few
    // addresses
    if (!changed || stat.type != FileSystemEntityType.file || stat.size > 64 * 1024) {
      continue;
    }
    try {
      if (File(path).readAsStringSync().contains(secret)) {
        found.add(p.basename(path));
      }
    } catch (_) {
      // Another program's file, binary, locked or already gone: not one of this test
    }
  }
  return found;
}

/// A check of the temporary folder takes well under a second even with tens of thousands of files there: one that
/// hangs fails in 10 seconds, not 30
const _tempCheckTimeout = Timeout(Duration(seconds: 10));

void main() {
  late List<File> listFiles;
  late _FakeNativePlayer native;

  setUp(() {
    listFiles = [];
    native = _FakeNativePlayer(listFiles);
  });

  tearDown(() async {
    for (final file in listFiles) {
      if (file.existsSync()) {
        await file.delete();
      }
    }
  });

  final cases = [
    (PlayerKind.playback, _bridgeUrl, _token),
    (PlayerKind.thumbnail, _bridgeUrl, _token),
    (PlayerKind.live, _liveAddress, 'CamPassword42'),
  ];
  for (final (kind, address, secret) in cases) {
    test('${kind.name}: opening writes no file in the temporary folder, mpv gets the address itself', () async {
      final player = await DesktopPlayer.withPlatform(kind, native);
      final watch = _FileWatch();
      final before = _tempTopLevel();
      native.calls.clear();
      await IOOverrides.runWithIOOverrides(
        () => player.open(address, start: const Duration(seconds: 3), streamed: true),
        watch,
      );

      expect(watch.paths, isEmpty, reason: 'DesktopPlayer.open makes no file at all');
      expect(_tempFilesHolding(secret, before), isEmpty);
      expect(native.opens, 0, reason: "media_kit's open, and its list file, are never used");
      expect(native.commands, [
        ['loadfile', address, 'replace'],
      ]);
      // media_kit's stop resets its state first, the file loads paused, and nothing turns references back on
      expect(native.calls.indexOf('stop'), lessThan(native.calls.indexOf('set pause=yes')));
      expect(native.calls.last, 'loadfile $address replace');
      expect(native.calls.where((call) => call.startsWith('set access-references')), isEmpty);
      await player.dispose();
    }, timeout: _tempCheckTimeout);
  }

  test(
    "the check of the temporary folder sees media_kit's list file (the open DesktopPlayer no longer uses)",
    () async {
      final watch = _FileWatch();
      final before = _tempTopLevel();
      await IOOverrides.runWithIOOverrides(
        () => Player(platformPlayer: native).open(Media(_bridgeUrl), play: false),
        watch,
      );
      final listFile = listFiles.single.path;
      // Each check sees it on its own: the watch as the open makes it, the look at the folder once it is there
      expect(watch.paths, contains(listFile));
      expect(_tempFilesHolding(_token, before), [p.basename(listFile)]);
    },
    timeout: _tempCheckTimeout,
  );

  test('a path of this computer opens as itself, a second open replaces the first', () async {
    final player = await DesktopPlayer.withPlatform(PlayerKind.playback, native);
    final path = p.join(Directory.systemTemp.path, 'Videos', 'clip.mp4');
    await player.open(path);
    await player.open(_bridgeUrl, streamed: true);
    expect(native.opens, 0);
    expect(native.commands, [
      ['loadfile', mpvAddress(path), 'replace'],
      ['loadfile', _bridgeUrl, 'replace'],
    ]);
    await player.dispose();
  });

  test('references are off from the creation of every player', () async {
    for (final kind in PlayerKind.values) {
      final fake = _FakeNativePlayer(listFiles);
      final player = await DesktopPlayer.withPlatform(kind, fake);
      expect(fake.properties['access-references'], 'no', reason: kind.name);
      await player.dispose();
    }
  });

  test('the start of the open is set as mpv loads the file, for that open only', () async {
    final player = await DesktopPlayer.withPlatform(PlayerKind.playback, native);
    await player.open(_bridgeUrl, start: const Duration(milliseconds: 12500), streamed: true);
    await native.load();
    expect(native.properties['start'], '12.500');

    native.properties.remove('start');
    await player.open(_bridgeUrl, streamed: true);
    await native.load();
    expect(native.properties.containsKey('start'), isFalse, reason: 'an open from the beginning sets no start');

    await player.open(_bridgeUrl, start: const Duration(seconds: 4), streamed: true);
    await player.stop();
    await native.load();
    expect(native.properties.containsKey('start'), isFalse, reason: 'a stop forgets the start of the last open');
    await player.dispose();
  });

  test('a live stream has no start', () async {
    final player = await DesktopPlayer.withPlatform(PlayerKind.live, native);
    await player.open(_liveAddress, start: const Duration(seconds: 5), streamed: true);
    await native.load();
    expect(native.properties.containsKey('start'), isFalse);
    await player.dispose();
  });

  group('mpvAddress', () {
    test('a URL is given as it is', () {
      for (final windows in [true, false]) {
        expect(mpvAddress(_bridgeUrl, windows: windows), _bridgeUrl);
        expect(mpvAddress(_liveAddress, windows: windows), _liveAddress);
      }
    });

    test("on Windows, a path behind the long path prefix, as media_kit's open gave it", () {
      expect(mpvAddress(r'C:\Users\me\Videos\clip.mp4', windows: true), r'\\?\C:\Users\me\Videos\clip.mp4');
      expect(mpvAddress('D:/Videos/Trips/../clip.mp4', windows: true), r'\\?\D:\Videos\clip.mp4');
      expect(mpvAddress(r'\\?\C:\Videos\clip.mp4', windows: true), r'\\?\C:\Videos\clip.mp4');
      expect(mpvAddress(r'\\nas\share\clip.mp4', windows: true), r'\\nas\share\clip.mp4');
      expect(mpvAddress('//nas/share/clip.mp4', windows: true), r'\\nas\share\clip.mp4');
    });

    test('elsewhere, a path as it is', () {
      expect(mpvAddress('/home/me/Videos/clip.mp4', windows: false), '/home/me/Videos/clip.mp4');
    });
  });
}
