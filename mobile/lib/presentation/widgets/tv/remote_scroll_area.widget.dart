import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';

/// A read only text of a TV screen that the remote scrolls, a notice for instance: one stop of the focus around a
/// scroll view that holds none of its own. Without it the arrows jump from the top of such a text to the button under
/// it, and a remote without channel keys (those of Chromecast with Google TV and of many boxes) never shows its last
/// lines.
///
/// Up and down, channel up and down, and OK scroll it by most of its height. At its end, down moves the focus on as on
/// any other part of the page, and OK does the same, so that the button under the text is reached only once its last
/// line was in view; at its top, up moves the focus up. The scroll view comes from [builder], with the controller it
/// must use; a scroll bar shows how much is left.
class RemoteScrollArea extends StatefulWidget {
  const RemoteScrollArea({super.key, required this.builder, this.autofocus = false});

  final Widget Function(BuildContext context, ScrollController controller) builder;
  final bool autofocus;

  /// The share of the visible height that one key scrolls: the last lines of the screen before stay in view
  static const step = 0.8;

  static const duration = Duration(milliseconds: 200);

  @override
  State<RemoteScrollArea> createState() => _RemoteScrollAreaState();
}

class _RemoteScrollAreaState extends State<RemoteScrollArea> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_controller.hasClients) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final ok = remoteOkKeys.contains(key);
    final arrow = key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp;
    final page = key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp;
    if (!ok && !arrow && !page) {
      return KeyEventResult.ignored;
    }
    if (ok && event is KeyRepeatEvent) {
      // A held OK reads on once, it does not race to the button
      return KeyEventResult.handled;
    }
    final down = ok ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.pageDown;
    final position = _controller.position;
    final step = max(position.viewportDimension * RemoteScrollArea.step, 48.0);
    final target = (position.pixels + (down ? step : -step)).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) {
      if (ok) {
        // At the end: OK goes on to what follows, as down does
        node.focusInDirection(TraversalDirection.down);
        return KeyEventResult.handled;
      }
      // At the end the arrows move the focus, as anywhere on the page; the channel keys have nothing left to scroll
      return arrow ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    unawaited(_controller.animateTo(target, duration: RemoteScrollArea.duration, curve: Curves.easeOut));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.autofocus,
    onKeyEvent: _onKey,
    child: Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: widget.builder(context, _controller),
    ),
  );
}
