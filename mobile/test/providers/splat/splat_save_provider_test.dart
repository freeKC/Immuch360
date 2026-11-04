// The words of a save (plan of 3 November 2026, section 6.2): what the page of the splat viewer, the sheet and the snack
// bars say of each state of a SplatSaveJob, in the app's language.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/splat/splat_save.provider.dart';

import '../../widget_tester_extensions.dart';

void main() {
  testWidgets('each state has its line', (tester) async {
    await tester.pumpConsumerWidget(const SizedBox());
    final t = StaticTranslations.instance;
    final date = DateTime(2026, 11, 3, 15, 53);
    String? line(SplatSaveStatus status, {int? plyBytes}) =>
        splatSaveLine(t, 'en', status, name: 'room.spz', sceneDate: date, plyBytes: plyBytes);

    expect(line(const SplatSaveStatus(SplatSaveState.idle)), isNull);
    expect(line(const SplatSaveStatus(SplatSaveState.cancelled)), isNull);
    expect(line(const SplatSaveStatus(SplatSaveState.drawing)), 'Preparing room.spz for Immich');
    expect(line(const SplatSaveStatus(SplatSaveState.writing, share: 0.5)), 'Preparing room.spz for Immich: 50 %');
    expect(line(const SplatSaveStatus(SplatSaveState.uploading, share: 0.25)), 'Sending room_splat.jpg: 25 %');
    expect(line(const SplatSaveStatus(SplatSaveState.done)), 'Saved to Immich, in your timeline on Nov 3, 2026');
    expect(
      line(const SplatSaveStatus(SplatSaveState.done, sceneBytes: 3 << 20), plyBytes: 12 << 20),
      'Saved to Immich, in your timeline on Nov 3, 2026. Saved as SPZ: 3.0 MiB instead of 12.0 MiB, the same gaussians',
    );
    expect(
      line(SplatSaveStatus(SplatSaveState.alreadyThere, savedAt: DateTime(2026, 10, 30, 12))),
      'Already on your Immich server: room.spz, saved on Oct 30, 2026',
    );
    expect(
      line(
        const SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.refusedSize, carrierBytes: 150 << 20),
      ),
      'Your server refused a file this large (150.0 MiB): a proxy in front of it limits uploads',
    );
    // An unreachable server in the app's words, not those of the socket
    expect(
      line(
        const SplatSaveStatus(
          SplatSaveState.failed,
          problem: SplatSaveProblem.unreachable,
          detail: 'SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
        ),
      ),
      'Not saved to Immich: Server Offline',
    );
    expect(
      line(const SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.plyTooLarge)),
      'This PLY is too large to convert on this device: save it from a computer',
    );
  });
}
