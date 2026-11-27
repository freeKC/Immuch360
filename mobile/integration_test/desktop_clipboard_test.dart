// The copy of photos and videos to the clipboard of the system (lib/desktop/clipboard) in a built app: the channel of
// the runner of this computer (windows/runner/clipboard_channel.cpp, linux/runner/clipboard_channel.cc,
// macos/Runner/MainFlutterWindow.swift) written through the copier the menus use, then read back by another program,
// as a paste would read it:
// - Windows: Windows PowerShell and System.Windows.Forms (the file drop list, "Preferred DropEffect", the bitmap);
// - Linux: xclip on the X server of xvfb-run (TARGETS, text/uri-list, x-special/gnome-copied-files, image/png);
// - macOS: osascript in JavaScript over NSPasteboard (the file URL of each item, its types, the PNG).
// One photo (its file and its picture, whose size is checked), one video (its file only), two files (both, in order,
// no picture), a remote file fetched first into the copies folder under its real name; then another program copies
// something else, after which the clipboard no longer holds the write and the copies folder goes.
// Run in the build jobs of the desktop workflow, and by hand on a Linux machine:
//   xvfb-run -a flutter test integration_test/desktop_clipboard_test.dart -d linux
// Never on a computer someone works on: it replaces what the clipboard holds.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/clipboard/desktop_clipboard.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// What another program reads from the clipboard
class _Read {
  _Read({required this.files, required this.hasPicture, this.width, this.height, this.extra = const {}});

  final List<String> files;
  final bool hasPicture;
  final int? width;
  final int? height;
  final Map<String, Object?> extra;

  @override
  String toString() => 'files $files, picture $hasPicture ${width}x$height, $extra';
}

/// [value], a number of the JSON of a reader, as an int
int _int(Object? value) => value is num ? value.toInt() : 0;

Future<ProcessResult> _run(String executable, List<String> arguments, {bool binary = false}) async {
  final result = await Process.run(executable, arguments, stdoutEncoding: binary ? null : utf8, stderrEncoding: utf8);
  return result;
}

const _windowsRead = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$data = [System.Windows.Forms.Clipboard]::GetDataObject()
$files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
$image = [System.Windows.Forms.Clipboard]::GetImage()
$effect = -1
$stream = $data.GetData('Preferred DropEffect')
if ($stream) { $effect = $stream.ReadByte() }
$png = 0
$pngStream = $data.GetData('PNG')
if ($pngStream) { $png = $pngStream.Length }
[pscustomobject]@{
  files = $files
  formats = @($data.GetFormats())
  width = $(if ($image) { $image.Width } else { 0 })
  height = $(if ($image) { $image.Height } else { 0 })
  effect = $effect
  png = $png
} | ConvertTo-Json -Compress -Depth 3
''';

const _macRead = r'''
ObjC.import('AppKit');
var pasteboard = $.NSPasteboard.generalPasteboard;
var items = pasteboard.pasteboardItems;
var files = [];
var types = [];
for (var i = 0; i < items.count; i++) {
  var item = items.objectAtIndex(i);
  var url = item.stringForType('public.file-url');
  files.push(url.isNil() ? '' : ObjC.unwrap(url));
  var itemTypes = item.types;
  var names = [];
  for (var j = 0; j < itemTypes.count; j++) {
    names.push(ObjC.unwrap(itemTypes.objectAtIndex(j)));
  }
  types.push(names);
}
var png = 0;
var width = 0;
var height = 0;
if (items.count > 0) {
  var data = items.objectAtIndex(0).dataForType('public.png');
  if (!data.isNil()) {
    png = data.length;
    var rep = $.NSBitmapImageRep.imageRepWithData(data);
    width = rep.pixelsWide;
    height = rep.pixelsHigh;
  }
}
JSON.stringify({files: files, types: types, png: png, width: width, height: height});
''';

/// The width and height a PNG declares in its IHDR, null for another file
(int, int)? _pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) {
    return null;
  }
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) {
      return null;
    }
  }
  final header = ByteData.sublistView(bytes, 16, 24);
  return (header.getUint32(0), header.getUint32(4));
}

/// The clipboard as another program of this computer reads it
Future<_Read> _readClipboard() async {
  if (Platform.isWindows) {
    final result = await _run('powershell', ['-NoProfile', '-STA', '-Command', _windowsRead]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final json = jsonDecode('${result.stdout}'.trim()) as Map<String, Object?>;
    final files = json['files'];
    final width = _int(json['width']);
    return _Read(
      files: files is List ? [for (final file in files) '$file'] : [if (files != null) '$files'],
      hasPicture: width > 0,
      width: width,
      height: _int(json['height']),
      extra: {'formats': json['formats'], 'effect': json['effect'], 'png': json['png']},
    );
  }
  if (Platform.isMacOS) {
    final result = await _run('osascript', ['-l', 'JavaScript', '-e', _macRead]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final json = jsonDecode('${result.stdout}'.trim()) as Map<String, Object?>;
    final files = [
      for (final url in json['files'] as List? ?? const [])
        if ('$url'.isNotEmpty) Uri.parse('$url').toFilePath(),
    ];
    final png = _int(json['png']);
    return _Read(
      files: files,
      hasPicture: png > 0,
      width: _int(json['width']),
      height: _int(json['height']),
      extra: {'types': json['types']},
    );
  }
  // Linux: xclip asks the app, which serves the selection while it runs
  Future<ProcessResult> xclip(String target, {bool binary = false}) =>
      _run('xclip', ['-selection', 'clipboard', '-t', target, '-o'], binary: binary);
  final targets = await xclip('TARGETS');
  expect(targets.exitCode, 0, reason: '${targets.stderr}');
  final targetList = LineSplitter.split(targets.stdout as String).map((line) => line.trim()).toList();
  final uris = await xclip('text/uri-list');
  expect(uris.exitCode, 0, reason: '${uris.stderr}');
  final files = [
    for (final line in LineSplitter.split(uris.stdout as String))
      if (line.trim().isNotEmpty && !line.startsWith('#')) Uri.parse(line.trim()).toFilePath(),
  ];
  final gnome = await xclip('x-special/gnome-copied-files');
  expect(gnome.exitCode, 0, reason: '${gnome.stderr}');
  int? width;
  int? height;
  final hasPicture = targetList.contains('image/png');
  if (hasPicture) {
    final png = await xclip('image/png', binary: true);
    expect(png.exitCode, 0, reason: '${png.stderr}');
    final size = _pngSize(Uint8List.fromList(png.stdout as List<int>));
    expect(size, isNotNull, reason: 'image/png must be a PNG');
    (width, height) = size!;
  }
  return _Read(
    files: files,
    hasPicture: hasPicture,
    width: width,
    height: height,
    extra: {'targets': targetList, 'gnome': gnome.stdout},
  );
}

/// Another program copies some text: the write of the app is no longer on the clipboard
Future<void> _copyElsewhere() async {
  final ProcessResult result;
  if (Platform.isWindows) {
    result = await _run('powershell', ['-NoProfile', '-STA', '-Command', 'Set-Clipboard -Value "another program"']);
  } else if (Platform.isMacOS) {
    result = await _run('sh', ['-c', 'printf "another program" | pbcopy']);
  } else {
    // xclip keeps the selection in a process of its own, which ends with the X server of xvfb-run; its output goes
    // nowhere, so that this does not wait for that process
    result = await _run('sh', ['-c', 'printf "another program" | xclip -selection clipboard >/dev/null 2>&1']);
  }
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

/// A PNG photo of [width] by [height], drawn by the engine
Future<Uint8List> _photo(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFF2266AA))
    ..drawCircle(Offset(width / 2, height / 2), height / 3, Paint()..color = const Color(0xFFFFCC00));
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Whether [a] and [b] name the same file: Windows ignores the case, macOS has /var under /private
bool _samePath(String a, String b) {
  String real(String path) => File(path).existsSync() ? File(path).resolveSymbolicLinksSync() : path;
  return Platform.isWindows ? p.equals(a.toLowerCase(), b.toLowerCase()) : p.equals(real(a), real(b));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('photos and videos reach the clipboard of the system as another program reads them', (tester) async {
    final work = await Directory.systemTemp.createTemp('immuch360-clipboard-test');
    final root = Directory(p.join(work.path, 'copies'));
    final copier = ClipboardCopier(root: () async => root);
    const clipboard = ChannelDesktopClipboard();

    // One photo: its file and its picture, at its size; a name with a space and an accent
    final photo = File(p.join(work.path, 'photo été 1.png'))..writeAsBytesSync(await _photo(320, 200));
    var result = await copier.copy([LocalClipboardSource(photo.path, isVideo: false)]);
    expect(result, (files: 1, picture: true));
    var read = await _readClipboard();
    debugPrint('One photo: $read');
    expect(read.files, hasLength(1));
    expect(_samePath(read.files.single, photo.path), isTrue, reason: '$read');
    expect(read.hasPicture, isTrue, reason: '$read');
    expect((read.width, read.height), (320, 200));
    if (Platform.isWindows) {
      expect(read.extra['effect'], 1, reason: 'Explorer must copy, never move');
      expect(read.extra['formats'], containsAll(['FileDrop', 'PNG']));
    } else if (Platform.isLinux) {
      expect(read.extra['targets'], containsAll(['text/uri-list', 'x-special/gnome-copied-files', 'image/png']));
      expect(read.extra['gnome'], 'copy\n${Uri.file(photo.path)}');
    } else {
      expect((read.extra['types'] as List?)?.first, containsAll(['public.file-url', 'public.png', 'public.tiff']));
    }

    // One video: its file only
    final video = File(p.join(work.path, 'clip.mp4'))..writeAsBytesSync(List<int>.filled(4096, 7));
    result = await copier.copy([LocalClipboardSource(video.path, isVideo: true)]);
    expect(result, (files: 1, picture: false));
    read = await _readClipboard();
    debugPrint('One video: $read');
    expect(read.files, hasLength(1));
    expect(_samePath(read.files.single, video.path), isTrue, reason: '$read');
    expect(read.hasPicture, isFalse, reason: '$read');

    // Two items: both files in order, no picture
    result = await copier.copy([
      LocalClipboardSource(photo.path, isVideo: false),
      LocalClipboardSource(video.path, isVideo: true),
    ]);
    expect(result, (files: 2, picture: false));
    read = await _readClipboard();
    debugPrint('Two items: $read');
    expect(read.files, hasLength(2));
    expect(_samePath(read.files[0], photo.path) && _samePath(read.files[1], video.path), isTrue, reason: '$read');
    expect(read.hasPicture, isFalse, reason: '$read');

    // A remote photo: fetched into the copies folder under its real name, then on the clipboard with its picture
    final remoteBytes = await _photo(64, 48);
    result = await copier.copy([
      RemoteClipboardSource(
        name: 'IMG_0042.png',
        isVideo: false,
        fetch: (abort) async =>
            http.StreamedResponse(Stream.value(remoteBytes), HttpStatus.ok, contentLength: remoteBytes.length),
      ),
    ]);
    expect(result, (files: 1, picture: true));
    read = await _readClipboard();
    debugPrint('A remote photo: $read');
    expect(p.basename(read.files.single), 'IMG_0042.png');
    expect(_samePath(p.dirname(p.dirname(read.files.single)), root.path), isTrue, reason: '$read');
    expect(File(read.files.single).readAsBytesSync(), remoteBytes);
    expect((read.width, read.height), (64, 48));
    final folders = root.listSync().whereType<Directory>().toList();
    expect(folders, hasLength(1));
    final marker = jsonDecode(File(p.join(folders.single.path, clipboardCopyMarker)).readAsStringSync()) as Map;
    final token = _int(marker['token']);
    expect(await clipboard.holds(token), isTrue, reason: 'nothing was copied since');

    // Another program copies: the write is no longer held, and its copies go
    await _copyElsewhere();
    // The app hears of it from the X server on Linux
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await clipboard.holds(token), isFalse, reason: 'another program copied since');
    final deleted = await cleanClipboardCopies(
      root,
      holds: clipboard.holds,
      systemTokens: !Platform.isLinux,
      minAge: Duration.zero,
    );
    expect(deleted, 1);
    expect(folders.single.existsSync(), isFalse);

    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // the runner's temporary folder goes with it
    }
  });
}
