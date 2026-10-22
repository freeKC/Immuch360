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
              _line(frame),
              style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String _line(DjiLinkFrame frame) {
    final kind = frame.isAcknowledgement ? 'ack' : 'req';
    final encryption = frame.encryption == 0 ? '' : ' encrypted:${frame.encryption}';
    return 'ch${frame.channel} set ${frame.commandSet} id ${frame.commandId} $kind a${frame.ackPolicy} '
        'from ${frame.senderType} to ${frame.receiverType} seq ${frame.sequence} len ${frame.length}'
        '$encryption ${frame.preview}';
  }
}
