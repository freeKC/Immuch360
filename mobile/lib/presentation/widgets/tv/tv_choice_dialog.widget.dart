import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// One choice of [showTvChoiceDialog]
class TvChoice<T> {
  const TvChoice({required this.value, required this.label, this.icon, this.key});

  final T value;
  final String label;

  /// Before the label; the labels stay aligned when only some choices have one
  final IconData? icon;

  /// The key of the tile of this choice
  final Key? key;
}

/// Above this many choices, [showTvChoiceDialog] builds only the tiles on screen: the cities of a whole library run
/// into the hundreds
const tvChoiceDialogLazyAbove = 50;

/// Asks for one of [choices] in a dialog, for the remote control layout, where a menu does not hold the focus: the
/// arrows and Back moved the focus out of an open menu to the page under it, the menu still open. A dialog is a route
/// of its own and keeps the focus until it closes. The choice whose value is [current] is marked and has the focus
/// first (the first choice when none is current), scrolled into view in a long list. Gives back the value chosen, or
/// null when Back closes the dialog.
Future<T?> showTvChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<TvChoice<T>> choices,
  required T current,
}) => showDialog<T>(
  context: context,
  builder: (_) => choices.length > tvChoiceDialogLazyAbove
      ? _LazyTvChoiceDialog<T>(title: title, choices: choices, current: current)
      : _TvChoiceDialog<T>(title: title, choices: choices, current: current),
);

/// The tile of the choice at [index] of [choices]; [height], in the lazy list, makes it one line of that height
Widget _choiceTile<T>(
  BuildContext context, {
  required List<TvChoice<T>> choices,
  required int index,
  required int focusIndex,
  required T current,
  double? height,
}) {
  final choice = choices[index];
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ListTile(
      key: choice.key,
      autofocus: index == focusIndex,
      selected: choice.value == current,
      selectedColor: context.colorScheme.onPrimary,
      selectedTileColor: context.colorScheme.primary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      minTileHeight: height,
      leading: choice.icon == null ? const SizedBox.square(dimension: 24) : Icon(choice.icon),
      title: height == null
          ? Text(choice.label)
          : Text(choice.label, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
      onTap: () => Navigator.of(context).pop(choice.value),
    ),
  );
}

/// The choice that has the focus first: the current one, else the first one
int _focusIndex<T>(List<TvChoice<T>> choices, T current) {
  final index = choices.indexWhere((choice) => choice.value == current);
  return index < 0 ? 0 : index;
}

/// The dialog of up to [tvChoiceDialogLazyAbove] choices. Its list may still run past the screen of a TV (the months
/// and the days of the TV date range): it opens scrolled to the choice that has the focus, which the autofocus alone
/// leaves where it is, out of sight, so that the first Down went past it.
class _TvChoiceDialog<T> extends StatefulWidget {
  const _TvChoiceDialog({required this.title, required this.choices, required this.current});

  final String title;
  final List<TvChoice<T>> choices;
  final T current;

  @override
  State<_TvChoiceDialog<T>> createState() => _TvChoiceDialogState<T>();
}

class _TvChoiceDialogState<T> extends State<_TvChoiceDialog<T>> {
  final _focusTile = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Once the list is laid out: the focused choice in the middle of the list, or as near as its ends allow
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tile = _focusTile.currentContext;
      if (mounted && tile != null) {
        unawaited(Scrollable.ensureVisible(tile, alignment: 0.5));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final focusIndex = _focusIndex(widget.choices, widget.current);
    return SimpleDialog(
      title: Text(widget.title),
      children: [
        for (var index = 0; index < widget.choices.length; index++)
          KeyedSubtree(
            key: index == focusIndex ? _focusTile : null,
            child: _choiceTile(
              context,
              choices: widget.choices,
              index: index,
              focusIndex: focusIndex,
              current: widget.current,
            ),
          ),
      ],
    );
  }
}

/// [_TvChoiceDialog] for a long list: a lazy list of tiles of one height, opened on the current choice
class _LazyTvChoiceDialog<T> extends StatefulWidget {
  const _LazyTvChoiceDialog({required this.title, required this.choices, required this.current});

  final String title;
  final List<TvChoice<T>> choices;
  final T current;

  @override
  State<_LazyTvChoiceDialog<T>> createState() => _LazyTvChoiceDialogState<T>();
}

class _LazyTvChoiceDialogState<T> extends State<_LazyTvChoiceDialog<T>> {
  /// The padding of the list, as SimpleDialog puts around its choices
  static const _padding = EdgeInsets.fromLTRB(0, 12, 0, 16);

  /// Made at the first layout, when the height of the list is known
  ScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// The height of a one line ListTile: 56 dp, more with a larger text
  double _tileHeight(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.listTileTheme.titleTextStyle ?? theme.textTheme.bodyLarge;
    final line = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 16) * (style?.height ?? 1.5);
    return max(56 + theme.visualDensity.baseSizeAdjustment.dy, line.ceilToDouble() + 16);
  }

  /// The scroll offset that puts the tile at [index] in the middle of a list [viewport] high, within the list
  double _offsetFor(int index, double tileHeight, double viewport) {
    final length = _padding.vertical + widget.choices.length * tileHeight;
    final centered = _padding.top + index * tileHeight - (viewport - tileHeight) / 2;
    return centered.clamp(0, max(0, length - viewport)).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focusIndex = _focusIndex(widget.choices, widget.current);
    final tileHeight = _tileHeight(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Text(widget.title, style: theme.dialogTheme.titleTextStyle ?? theme.textTheme.headlineSmall),
            ),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _controller ??= ScrollController(
                    initialScrollOffset: _offsetFor(focusIndex, tileHeight, constraints.maxHeight),
                  );
                  return ListView.builder(
                    controller: _controller,
                    padding: _padding,
                    itemExtent: tileHeight,
                    itemCount: widget.choices.length,
                    itemBuilder: (context, index) => _choiceTile(
                      context,
                      choices: widget.choices,
                      index: index,
                      focusIndex: focusIndex,
                      current: widget.current,
                      height: tileHeight,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
