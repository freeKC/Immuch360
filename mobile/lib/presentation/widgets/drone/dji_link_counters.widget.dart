// The traffic of the DJI link page: one row per channel, then the counters of everything thrown away or not
// understood. A counter is the evidence of a session on this hardware, so none of them is hidden when it is zero.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// A label and a value on one line, the shape every block of this page uses
class DjiLinkFact extends StatelessWidget {
  const DjiLinkFact(this.label, this.value, {super.key, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: Text(label, style: context.textTheme.bodySmall)),
        Expanded(
          flex: 4,
          child: Text(
            value,
            style: context.textTheme.bodySmall?.copyWith(
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    ),
  );
}

class DjiLinkChannelsTable extends StatelessWidget {
  const DjiLinkChannelsTable({super.key, required this.channels});

  final List<DjiLinkChannel> channels;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (channels.isEmpty) {
      return Text(t.dji_link_no_frames, style: context.textTheme.bodySmall);
    }
    return Table(
      key: const Key('dji_link_channels'),
      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2), 3: FlexColumnWidth(2)},
      children: [
        TableRow(
          children: [
            _head(context, t.dji_link_channel),
            _head(context, t.dji_link_frames),
            _head(context, t.dji_link_bytes),
            _head(context, t.dji_link_largest),
          ],
        ),
        for (final channel in channels)
          TableRow(
            children: [
              _cell(context, '${channel.channel} ${djiLinkRoleText(t, channel.role)}'),
              _cell(context, '${channel.envelopes}'),
              _cell(context, formatHumanReadableBytes(channel.bytes, 1)),
              _cell(context, '${channel.largestPayload}'),
            ],
          ),
      ],
    );
  }

  Widget _head(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(text, style: context.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
  );

  Widget _cell(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text, style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
  );
}

class DjiLinkCountersBlock extends StatelessWidget {
  const DjiLinkCountersBlock({super.key, required this.counters});

  final DjiLinkCounters counters;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      key: const Key('dji_link_counters'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkFact(t.dji_link_counter_unknown_channels, '${counters.unknownChannelFrames}'),
        DjiLinkFact(t.dji_link_counter_false_syncs, '${counters.unknownChannelRejections}'),
        DjiLinkFact(t.dji_link_counter_resync, '${counters.resynchronisations}'),
        DjiLinkFact(t.dji_link_counter_discarded, '${counters.discardedBytes}'),
        DjiLinkFact(t.dji_link_counter_padding, '${counters.paddingBytes}'),
        DjiLinkFact(t.dji_link_counter_oversize, '${counters.oversizeRejections}'),
        DjiLinkFact(t.dji_link_counter_timeouts, '${counters.incompleteTimeouts}'),
        DjiLinkFact(t.dji_link_counter_header_crc, '${counters.headerCrcFailures}'),
        DjiLinkFact(t.dji_link_counter_frame_crc, '${counters.frameCrcFailures}'),
        DjiLinkFact(t.dji_link_counter_encryption, '${counters.unsupportedEncryption}'),
        DjiLinkFact(t.dji_link_counter_unknown_pairs, '${counters.unknownPairs}'),
        DjiLinkFact(t.dji_link_counter_ambiguous_side, '${counters.ambiguousSideFrames}'),
      ],
    );
  }
}

/// The checksum parameters in use, and the seed the failures point to. On noise the votes spread over many values;
/// real frames whose seed differs from the notes pile them on one, which a replay of the capture can then try.
class DjiLinkCrcBlock extends StatelessWidget {
  const DjiLinkCrcBlock({super.key, required this.crc});

  final DjiLinkCrc crc;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    String candidate(int? seed, int votes, int total, int digits) => seed == null
        ? t.dji_link_crc_no_votes
        : t.dji_link_crc_votes(seed: '0x${seed.toRadixString(16).padLeft(digits, '0')}', votes: votes, total: total);
    return Column(
      key: const Key('dji_link_crc'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkFact(t.dji_link_crc_parameters, '${crc.headerParameters} ${crc.frameParameters}'),
        DjiLinkFact(
          t.dji_link_crc_header_candidate,
          candidate(crc.headerSeedCandidate, crc.headerSeedVotes, crc.headerFailuresVoting, 2),
        ),
        DjiLinkFact(
          t.dji_link_crc_frame_candidate,
          candidate(crc.frameSeedCandidate, crc.frameSeedVotes, crc.frameFailuresVoting, 4),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.dji_link_crc_note, style: context.textTheme.bodySmall),
        ),
      ],
    );
  }
}
