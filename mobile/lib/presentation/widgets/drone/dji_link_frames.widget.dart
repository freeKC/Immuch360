// The parsed frames of the DJI link page, newest first and bounded by the native side. A frame whose encryption field
// is not zero shows its identifier and no preview: its body is not read anywhere in this application.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';

class DjiLinkFramesList extends StatelessWidget {
  const DjiLinkFramesList({super.key, required this.frames});

  final List<DjiLinkFrame> frames;

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty) {
      return Text(context.t.dji_link_no_frames, style: context.textTheme.bodySmall);
    }
    return Column(
      key: const Key('dji_link_frames'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final frame in frames)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              _line(context.t, frame),
              style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String _line(Translations t, DjiLinkFrame frame) {
    // Identifiers as plain digits: a number handed over as such gets the grouping of the locale, and a channel
    // written 22,345 is not the channel the notes and the capture call 22345
    final line = t.dji_link_frame_line(
      channel: '${frame.channel}',
      commandSet: '${frame.commandSet}',
      commandId: '${frame.commandId}',
      kind: frame.isAcknowledgement ? t.dji_link_frame_ack : t.dji_link_frame_request,
      ack: '${frame.ackPolicy}',
      from: '${frame.senderType}',
      to: '${frame.receiverType}',
      sequence: '${frame.sequence}',
      frameLength: '${frame.length}',
    );
    if (frame.encryption != 0) {
      return '$line, ${t.dji_link_frame_encrypted(value: frame.encryption)}';
    }
    return frame.preview.isEmpty ? line : '$line: ${frame.preview}';
  }
}
