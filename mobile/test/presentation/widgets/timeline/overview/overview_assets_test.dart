// The thumbnails of a block while the buckets change, as they do often during a sync: the previous pictures stay until
// the new ones are read, rather than a flash of empty cells on every block.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';

import '../../../../fixtures/asset.stub.dart';

void main() {
  testWidgets('the previous pictures stay while the buckets change, then the new ones come', (tester) async {
    final gates = <Completer<void>>[];
    var round = 0;
    final loader = OverviewAssetLoader((index, count) async {
      final read = round;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      return List<BaseAsset>.generate(count, (i) => LocalAssetStub.image1.copyWith(id: 'r$read-${index + i}'));
    });
    List<BaseAsset>? seen;
    List<String>? ids() => seen?.map((asset) => (asset as LocalAsset).id).toList();
    Widget block() => ProviderScope(
      child: OverviewAssets(
        loader: loader,
        index: 10,
        count: 3,
        builder: (_, assets) {
          seen = assets;
          return const SizedBox.shrink();
        },
      ),
    );

    await tester.pumpWidget(block());
    expect(seen, isNull, reason: 'nothing read yet');
    await tester.pump();
    expect(gates, hasLength(1));
    gates.single.complete();
    // The read ends, then the frame of the block
    await tester.pump();
    await tester.pump();
    expect(ids(), ['r0-10', 'r0-11', 'r0-12']);

    // The buckets change: the timeline clears the loader and builds its blocks again
    round = 1;
    loader.clear();
    await tester.pumpWidget(block());
    expect(ids(), ['r0-10', 'r0-11', 'r0-12'], reason: 'the previous pictures stay meanwhile');
    await tester.pump();
    expect(gates, hasLength(2), reason: 'read again');
    gates.last.complete();
    await tester.pump();
    await tester.pump();
    expect(ids(), ['r1-10', 'r1-11', 'r1-12']);
  });
}
