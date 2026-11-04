// What the app itself holds of a graphics card on Linux, from the DRM fdinfo of its own files (issue #13): the regions
// local to the card only, the keys of each driver and their units, one client counted once whatever the number of its
// files, the card chosen by its PCI address; nothing for the cards that write no memory there (the proprietary driver
// of NVIDIA, integrated graphics in the memory of the computer). The texts are those of the kernel's drm-usage-stats.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/gpu/app_graphics_memory.dart';
import 'package:path/path.dart' as p;

const _mib = 1 << 20;

/// amdgpu before Linux 6.9: `drm-memory-<region>` in KiB
const _amdgpu = '''
pos:	0
flags:	02100002
mnt_id:	26
ino:	1063
drm-driver:	amdgpu
drm-client-id:	14
drm-pdev:	0000:03:00.0
pasid:	32790
drm-memory-vram:	917504 KiB
drm-memory-gtt: 	2048 KiB
drm-memory-cpu: 	0 KiB
amd-memory-visible-vram:	917504 KiB
drm-engine-gfx:	9817438 ns
''';

/// amdgpu from Linux 6.9: `drm-resident-<region>` next to the older keys
const _amdgpuResident = '''
drm-driver:	amdgpu
drm-client-id:	21
drm-pdev:	0000:03:00.0
drm-total-vram:	1048576 KiB
drm-shared-vram:	0
drm-resident-vram:	524288 KiB
drm-memory-vram:	524288 KiB
drm-total-gtt:	4096 KiB
drm-resident-gtt:	4096 KiB
''';

/// xe on an Arc card: vram0 in bytes and stolen memory beside it
const _xe = '''
drm-driver:	xe
drm-client-id:	5
drm-pdev:	0000:03:00.0
drm-total-system:	0
drm-resident-system:	0
drm-total-gtt:	12 MiB
drm-resident-gtt:	12 MiB
drm-total-vram0:	300 MiB
drm-resident-vram0:	256 MiB
drm-total-stolen:	0
drm-cycles-rcs:	28257900
''';

/// i915 on an integrated card, the memory of the computer only: the keys of the render node of the Iris Xe of ai1
/// (Linux 6.12) as a process that opened it reads them, with 180 MiB in place of its zeros
const _i915Integrated = '''
pos:	0
flags:	02100002
mnt_id:	26
ino:	542
drm-driver:	i915
drm-client-id:	125
drm-pdev:	0000:00:02.0
drm-total-system0:	180 MiB
drm-shared-system0:	0
drm-active-system0:	0
drm-resident-system0:	180 MiB
drm-purgeable-system0:	0
drm-total-stolen-system0:	0
drm-shared-stolen-system0:	0
drm-active-stolen-system0:	0
drm-resident-stolen-system0:	0
drm-purgeable-stolen-system0:	0
drm-engine-render:	5122351 ns
drm-engine-copy:	0 ns
drm-engine-video:	0 ns
drm-engine-capacity-video:	2
drm-engine-video-enhance:	0 ns
''';

/// The proprietary driver of NVIDIA: no memory written
const _nvidia = '''
pos:	0
flags:	02100002
drm-driver:	nvidia-drm
drm-client-id:	3
drm-pdev:	0000:01:00.0
''';

void main() {
  group('one fdinfo text', () {
    test('amdgpu: the VRAM in KiB, never the GTT nor the processor', () {
      final client = parseDrmFdinfo(_amdgpu)!;
      expect(client.pci, '0000:03:00.0');
      expect(client.clientId, '14');
      expect(client.bytes, 896 * _mib);
    });

    test('the resident memory preferred to the total and to the older key', () {
      expect(parseDrmFdinfo(_amdgpuResident)!.bytes, 512 * _mib);
    });

    test('xe: vram0 in MiB, the system, the GTT and the stolen memory left out', () {
      expect(parseDrmFdinfo(_xe)!.bytes, 256 * _mib);
    });

    test('integrated graphics, the proprietary driver of NVIDIA, a file that is no DRM client: nothing told', () {
      expect(parseDrmFdinfo(_i915Integrated), isNull);
      expect(parseDrmFdinfo(_nvidia), isNull);
      expect(parseDrmFdinfo('pos:\t0\nflags:\t02\nmnt_id:\t15\nino:\t42\n'), isNull);
      expect(parseDrmFdinfo(''), isNull);
    });

    test('a local region without unit is in bytes, and "local0" counts as i915 names it on a dedicated card', () {
      final client = parseDrmFdinfo(
        'drm-driver:\ti915\ndrm-client-id:\t9\ndrm-pdev:\t0000:04:00.0\ndrm-total-local0:\t2097152\n'
        'drm-resident-local0:\t1048576\n',
      )!;
      expect(client.bytes, 1048576);
    });
  });

  group('the files of the app', () {
    test('a client opened twice counts once; the clients of the card added up; another card left out', () {
      final texts = [_amdgpu, _amdgpu, _amdgpuResident, _i915Integrated, _nvidia];
      expect(drmBytesOn('0000:03:00.0', texts), 896 * _mib + 512 * _mib);
      expect(drmBytesOn('0000:03:00.0'.toUpperCase(), texts), 896 * _mib + 512 * _mib);
      expect(drmBytesOn('0000:00:02.0', texts), isNull, reason: 'integrated: in the memory of the computer');
      expect(drmBytesOn('0000:01:00.0', texts), isNull, reason: 'NVIDIA writes no memory there: NVML tells it');
      expect(drmBytesOn('0000:07:00.0', texts), isNull);
    });

    test('read from the fdinfo folder of a process', () async {
      final proc = Directory.systemTemp.createTempSync('app_graphics_memory_test_');
      addTearDown(() => proc.deleteSync(recursive: true));
      final fdinfo = Directory(p.join(proc.path, 'fdinfo'))..createSync();
      File(p.join(fdinfo.path, '0')).writeAsStringSync('pos:\t0\nflags:\t02\n');
      File(p.join(fdinfo.path, '17')).writeAsStringSync(_xe);
      File(p.join(fdinfo.path, '18')).writeAsStringSync(_xe);
      File(p.join(fdinfo.path, '23')).writeAsStringSync(_i915Integrated);

      expect(await appDrmMemoryOn('0000:03:00.0', proc: proc.path), 256 * _mib);
      expect(await appDrmMemoryOn('0000:00:02.0', proc: proc.path), isNull);
      expect(await appDrmMemoryOn('0000:03:00.0', proc: p.join(proc.path, 'gone')), isNull);
    });

    test('this process, on a Linux computer: read without failing', () async {
      final held = await appDrmMemoryOn('0000:00:00.0');
      expect(held, anyOf(isNull, greaterThanOrEqualTo(0)));
    }, skip: Platform.isLinux ? false : 'fdinfo is Linux only');
  });
}
