import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/files/zip_writer.dart';

import 'zip_reader.dart';

void main() {
  test('the CRC-32 of the check string is the standard one', () {
    expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    expect(crc32(const []), 0);
  });

  test('entries come back whole, in order, with UTF-8 names', () {
    final noise = Uint8List.fromList(List.generate(70000, (index) => (index * 7919) % 251));
    final archive = zipFiles([
      ZipEntry(
        name: 'journal.log',
        bytes: utf8.encode('une ligne\n' * 200),
        modified: DateTime(2026, 10, 8, 10, 20, 31),
      ),
      ZipEntry(name: 'crash_dumps/été.dmp', bytes: noise, modified: DateTime(2026, 10, 8)),
      ZipEntry(name: 'empty.txt', bytes: Uint8List(0), modified: DateTime(1970)),
    ]);

    final entries = readZip(archive);
    expect(entries.keys, ['journal.log', 'crash_dumps/été.dmp', 'empty.txt']);
    expect(utf8.decode(entries['journal.log']!), 'une ligne\n' * 200);
    expect(entries['crash_dumps/été.dmp'], noise);
    expect(entries['empty.txt'], isEmpty);
    expect(archive.length, lessThan(noise.length + 2000), reason: 'deflated');
  });

  test('the dates are MS-DOS ones, two seconds apart, 1980 at the earliest', () {
    final archive = zipFiles([
      ZipEntry(name: 'a', bytes: Uint8List(1), modified: DateTime(2026, 10, 8, 10, 20, 31)),
      ZipEntry(name: 'b', bytes: Uint8List(1), modified: DateTime(1975, 5, 5)),
    ]);
    final data = ByteData.sublistView(archive);
    // Local header of the first entry: time at 10, date at 12
    expect(data.getUint16(10, Endian.little), (10 << 11) | (20 << 5) | 15);
    expect(data.getUint16(12, Endian.little), ((2026 - 1980) << 9) | (10 << 5) | 8);
    // The second local header follows the first one, its one letter name and its deflated byte
    final second = 30 + 1 + data.getUint32(18, Endian.little);
    final secondData = ByteData.sublistView(archive, second);
    expect(secondData.getUint32(0, Endian.little), 0x04034b50);
    expect(secondData.getUint16(12, Endian.little), (1 << 5) | 1);
  });

  test('a real unzip tool reads it: unzip where there is one, the archive support of Windows on Windows', () async {
    final folder = Directory.systemTemp.createTempSync('immuch360-zip');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}${Platform.pathSeparator}test.zip')
      ..writeAsBytesSync(
        zipFiles([
          ZipEntry(name: 'a/b.txt', bytes: utf8.encode('hello'), modified: DateTime.now()),
          ZipEntry(name: 'crash_dumps/été.dmp', bytes: Uint8List.fromList([1, 2, 3]), modified: DateTime.now()),
        ]),
      );

    if (Platform.isWindows) {
      // A reader that is not ours: the archive support Windows ships, through PowerShell's Expand-Archive. Quotes
      // doubled, in case the temporary folder's path holds one.
      final out = '${folder.path}${Platform.pathSeparator}out';
      String quoted(String path) => "'${path.replaceAll("'", "''")}'";
      final result = Process.runSync('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath ${quoted(file.path)} -DestinationPath ${quoted(out)}',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(File('$out\\a\\b.txt').readAsStringSync(), 'hello');
      expect(File('$out\\crash_dumps\\été.dmp').readAsBytesSync(), [1, 2, 3]);
      return;
    }

    final ProcessResult found;
    try {
      found = Process.runSync('unzip', ['-v']);
    } on ProcessException {
      markTestSkipped('no unzip here');
      return;
    }
    if (found.exitCode != 0) {
      markTestSkipped('no unzip here');
      return;
    }
    // unzip prints the names in its own encoding, which is not always UTF-8: read as bytes made characters
    final result = Process.runSync('unzip', ['-t', file.path], stdoutEncoding: latin1, stderrEncoding: latin1);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}
