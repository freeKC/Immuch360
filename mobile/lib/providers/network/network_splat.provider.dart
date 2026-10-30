// The Gaussian splat files of other tools on a Meta Quest (lot S5): whether they are listed and opened here, and what
// the head of each says. A .spz or .ply of a share (SMB, WebDAV) is read through the connection of its share, its
// first 64 KiB only; a file picked on the headset (Open a splat file) is read where the picker copied it.

import 'dart:io';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';

/// Whether the splats are listed in the shares and offered in the Add menu: on a Meta Quest, with Gaussian splats on
/// (experimental, on by default). The splat page itself says whether this headset and this APK can show one.
final networkSplatsEnabledProvider = Provider<bool>((ref) {
  final horizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
  return horizonOs && ref.watch(appConfigProvider.select((config) => config.viewer.gaussianSplats));
});

/// A splat file: a file of the share [sourceId] at [path] of [size] bytes when known, or a file of the headset at
/// [path] without a share
typedef SplatFileKey = ({String? sourceId, String path, int? size});

/// The length the probe takes for a file of a share whose size is unknown: its rows are then not checked
const _unknownLength = 1 << 50;

/// What the head of the splat file of [key] says (see probeSplatHead). Tests replace it.
final splatProbeProvider = FutureProvider.autoDispose.family<SplatProbe, SplatFileKey>((ref, key) async {
  final sourceId = key.sourceId;
  if (sourceId == null) {
    final file = File(key.path);
    final length = await file.length();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, splatHeadBytes)) {
      builder.add(chunk);
    }
    return probeSplatHead(builder.toBytes(), length);
  }
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
  final head = await fileSystem.readRange(key.path, 0, splatHeadBytes);
  return probeSplatHead(head, key.size ?? _unknownLength);
});
