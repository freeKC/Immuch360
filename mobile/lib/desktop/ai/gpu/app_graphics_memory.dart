// What this app itself holds of the memory of a graphics card on Linux, from the DRM fdinfo of its own files (issue
// #13). Each file the app opened on a card (/dev/dri/renderD128, card0: Flutter's renderer, the decoders and outputs of
// its video players) has a text in /proc/self/fdinfo/<fd> with the keys of the kernel's drm-usage-stats: the driver,
// the client id, the PCI address of the card (drm-pdev) and the memory of the client by region. Only the regions local
// to the card count: "vram" and "vram0" (amdgpu, xe, nouveau), "local0" (i915 on a dedicated card), never "system",
// "gtt", "cpu" or "stolen". "drm-resident-<region>" is preferred, then the "drm-memory-<region>" of older amdgpu, then
// "drm-total-<region>"; the units are "KiB", "MiB" or none (bytes). One client may be opened through several files: it
// counts once. Reading these texts calls no driver, so the app reads them itself; NVML and the counter of Windows are
// read by the probe in its child process (gpu_probe.dart). The proprietary driver of NVIDIA writes no memory there.

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AppGraphicsMemory');

/// What one fdinfo text tells of a DRM client: the card, the client, and its bytes in the memory local to the card
class DrmClientMemory {
  const DrmClientMemory({required this.pci, required this.clientId, required this.bytes});

  /// "0000:03:00.0", as drm-pdev writes it
  final String pci;
  final String clientId;
  final int bytes;
}

final _line = RegExp(r'^drm-(resident|memory|total)-([a-z]+[0-9]*):\s*(\d+)\s*(KiB|MiB|GiB)?\s*$');
final _key = RegExp(r'^(drm-[a-z-]+):\s*(\S+)');

int _bytes(String value, String? unit) =>
    int.parse(value) *
    switch (unit) {
      'KiB' => 1 << 10,
      'MiB' => 1 << 20,
      'GiB' => 1 << 30,
      _ => 1,
    };

bool _localRegion(String region) => region.startsWith('vram') || region.startsWith('local');

/// The DRM client [text] tells of, with its bytes in the regions local to the card; null when it is no DRM client or
/// tells no such memory (an integrated card, the proprietary driver of NVIDIA)
DrmClientMemory? parseDrmFdinfo(String text) {
  String? pci;
  String? client;
  // The bytes of each local region, by the kind of key that told them
  final byKind = <String, Map<String, int>>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final memory = _line.firstMatch(line);
    if (memory != null) {
      final region = memory.group(2)!;
      if (_localRegion(region)) {
        (byKind[memory.group(1)!] ??= {})[region] = _bytes(memory.group(3)!, memory.group(4));
      }
      continue;
    }
    final key = _key.firstMatch(line);
    switch (key?.group(1)) {
      case 'drm-pdev':
        pci = key!.group(2)!.toLowerCase();
      case 'drm-client-id':
        client = key!.group(2);
    }
  }
  final regions = byKind['resident'] ?? byKind['memory'] ?? byKind['total'];
  if (pci == null || client == null || regions == null) {
    return null;
  }
  return DrmClientMemory(pci: pci, clientId: client, bytes: regions.values.fold(0, (sum, bytes) => sum + bytes));
}

/// The bytes the clients of [texts] hold on the card at [pci], each client once; null when none of them tells any
int? drmBytesOn(String pci, Iterable<String> texts) {
  final card = pci.toLowerCase();
  final clients = <String, int>{};
  for (final text in texts) {
    final client = parseDrmFdinfo(text);
    if (client != null && client.pci == card) {
      clients[client.clientId] = client.bytes;
    }
  }
  return clients.isEmpty ? null : clients.values.fold<int>(0, (sum, bytes) => sum + bytes);
}

/// The bytes of the card at [pci] this process holds, from the fdinfo texts under [proc] (/proc/self); null when no
/// file of the process tells any, or off Linux
Future<int?> appDrmMemoryOn(String pci, {String proc = '/proc/self'}) async {
  final folder = Directory(p.join(proc, 'fdinfo'));
  final texts = <String>[];
  try {
    await for (final entry in folder.list(followLinks: false)) {
      try {
        texts.add(await File(entry.path).readAsString());
      } on FileSystemException {
        // A file closed meanwhile
      }
    }
  } on FileSystemException catch (error) {
    _log.fine('No fdinfo to read: ${error.message}');
    return null;
  }
  return drmBytesOn(pci, texts);
}
