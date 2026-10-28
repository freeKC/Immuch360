// The free space of a drive (lib/desktop/ai/components/disk_space.dart): read for real on the system of the test
// (GetDiskFreeSpaceExW on Windows, statvfs on Linux and macOS), from a folder that exists or not yet, and the space the
// installation of components asks for (design-final 2026-10-27, section 7.1, point 6).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/components/disk_space.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('disk-space'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the drive of a folder: some space free, no more than its size, and its name', () async {
    final space = await systemFreeSpace(temp);

    expect(space, isNotNull);
    expect(space!.free, greaterThan(0));
    expect(space.total, greaterThanOrEqualTo(space.free));
    expect(space.volume, isNotEmpty);
    if (Platform.isWindows) {
      expect(space.volume, matches(RegExp(r'^[A-Za-z]:$|^\\\\')));
    } else {
      expect(p.isAbsolute(space.volume), isTrue);
      expect(p.equals(space.volume, temp.path) || p.isWithin(space.volume, temp.path), isTrue);
    }
  });

  test('a folder not made yet is read on the drive of its nearest folder', () async {
    final later = Directory(p.join(temp.path, 'not', 'yet', 'ai-components'));

    final space = await systemFreeSpace(later);
    final parent = await systemFreeSpace(temp);

    expect(later.existsSync(), isFalse);
    expect(space?.volume, parent?.volume);
    expect(space?.total, parent?.total);
  });

  test('the space asked: what the components take plus a margin of 10 %, 1 GiB at least', () {
    const gib = 1024 * 1024 * 1024;
    expect(aiSpaceNeeded(100 * 1024 * 1024), 100 * 1024 * 1024 + gib);
    expect(aiSpaceNeeded(20 * gib), 22 * gib);
    expect(aiSpaceNeeded(0), 0);
  });
}
