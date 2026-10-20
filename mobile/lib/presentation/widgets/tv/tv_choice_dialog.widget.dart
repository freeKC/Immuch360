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

/// Asks for one of [choices] in a dialog, for the remote control layout, where a menu does not hold the focus: the
/// arrows and Back moved the focus out of an open menu to the page under it, the menu still open. A dialog is a route
/// of its own and keeps the focus until it closes. The choice whose value is [current] is marked and has the focus
/// first (the first choice when none is current). Gives back the value chosen, or null when Back closes the dialog.
Future<T?> showTvChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<TvChoice<T>> choices,
  required T current,
}) => showDialog<T>(
  context: context,
  builder: (_) => _TvChoiceDialog<T>(title: title, choices: choices, current: current),
);

class _TvChoiceDialog<T> extends StatelessWidget {
  const _TvChoiceDialog({required this.title, required this.choices, required this.current});

  final String title;
  final List<TvChoice<T>> choices;
  final T current;

  @override
  Widget build(BuildContext context) {
    final hasCurrent = choices.any((choice) => choice.value == current);
    return SimpleDialog(
      title: Text(title),
      children: [
        for (final (index, choice) in choices.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ListTile(
              key: choice.key,
              autofocus: hasCurrent ? choice.value == current : index == 0,
              selected: choice.value == current,
              selectedColor: context.colorScheme.onPrimary,
              selectedTileColor: context.colorScheme.primary,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              leading: choice.icon == null ? const SizedBox.square(dimension: 24) : Icon(choice.icon),
              title: Text(choice.label),
              onTap: () => Navigator.of(context).pop(choice.value),
            ),
          ),
      ],
    );
  }
}
