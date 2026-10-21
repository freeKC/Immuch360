import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_choice_dialog.widget.dart';

class SearchDropdown<T> extends StatelessWidget {
  const SearchDropdown({
    super.key,
    required this.dropdownMenuEntries,
    required this.controller,
    this.onSelected,
    this.label,
    this.leadingIcon,
  });

  final List<DropdownMenuEntry<T>> dropdownMenuEntries;
  final TextEditingController controller;
  final void Function(T?)? onSelected;

  /// The label of the field, and the title of the dialog of choices with a remote control
  final String? label;
  final Widget? leadingIcon;

  static const WidgetStatePropertyAll<EdgeInsetsGeometry> _optionPadding = WidgetStatePropertyAll<EdgeInsetsGeometry>(
    EdgeInsetsDirectional.fromSTEB(16, 0, 16, 0),
  );

  @override
  Widget build(BuildContext context) {
    // With a remote control, a DropdownMenu keeps the focus: its field takes Up and Down even while the menu is
    // closed, and OK (select) does not pick an entry of the open menu
    if (MediaQuery.navigationModeOf(context) == NavigationMode.directional) {
      return _RemoteSearchField<T>(
        entries: dropdownMenuEntries,
        controller: controller,
        onSelected: onSelected,
        label: label,
        leadingIcon: leadingIcon,
      );
    }

    final mediaQuery = MediaQuery.of(context);
    final maxMenuHeight = mediaQuery.size.height * 0.5 - mediaQuery.viewPadding.bottom;
    const menuStyle = MenuStyle(
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(15))),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final styledEntries = dropdownMenuEntries
            .map(
              (entry) => DropdownMenuEntry<T>(
                value: entry.value,
                label: entry.label,
                labelWidget: entry.labelWidget,
                enabled: entry.enabled,
                leadingIcon: entry.leadingIcon,
                trailingIcon: entry.trailingIcon,
                style: (entry.style ?? const ButtonStyle()).copyWith(padding: _optionPadding),
              ),
            )
            .toList(growable: false);

        return DropdownMenu(
          controller: controller,
          leadingIcon: leadingIcon,
          width: constraints.maxWidth,
          menuHeight: maxMenuHeight,
          dropdownMenuEntries: styledEntries,
          label: label == null ? null : Text(label!),
          menuStyle: menuStyle,
          trailingIcon: const Icon(Icons.arrow_drop_down_rounded),
          selectedTrailingIcon: const Icon(Icons.arrow_drop_up_rounded),
          onSelected: onSelected,
        );
      },
    );
  }
}

/// [SearchDropdown] in the remote control layout: one focus stop that looks like the field of the menu, and OK opens
/// the entries in a dialog, which holds the focus. A choice fills the field and calls [onSelected], as the menu does;
/// Back changes nothing. With no entries the field shows that there are none and stays a focus stop, so that the
/// arrows go through it as through the others.
class _RemoteSearchField<T> extends StatefulWidget {
  const _RemoteSearchField({
    required this.entries,
    required this.controller,
    required this.onSelected,
    required this.label,
    required this.leadingIcon,
  });

  final List<DropdownMenuEntry<T>> entries;
  final TextEditingController controller;
  final void Function(T?)? onSelected;
  final String? label;
  final Widget? leadingIcon;

  @override
  State<_RemoteSearchField<T>> createState() => _RemoteSearchFieldState<T>();
}

class _RemoteSearchFieldState<T> extends State<_RemoteSearchField<T>> {
  var _focused = false;

  static const _radius = BorderRadius.all(Radius.circular(15));

  Future<void> _choose() async {
    final entries = widget.entries.where((entry) => entry.enabled).toList();
    final text = widget.controller.text;
    final current = entries.where((entry) => entry.label == text).firstOrNull;
    final chosen = await showTvChoiceDialog<DropdownMenuEntry<T>?>(
      context: context,
      title: widget.label ?? '',
      choices: [for (final entry in entries) TvChoice(value: entry, label: entry.label)],
      current: current,
    );
    if (chosen == null || !mounted) {
      return;
    }
    widget.controller.text = chosen.label;
    widget.onSelected?.call(chosen.value);
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.entries.isEmpty;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) => InkWell(
        // Disabled controls keep the focus in the remote control layout
        onTap: empty ? null : _choose,
        onFocusChange: (focused) => setState(() => _focused = focused),
        borderRadius: _radius,
        child: InputDecorator(
          isEmpty: value.text.isEmpty,
          isFocused: _focused,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: empty ? context.t.no_results : null,
            // The hint shows only above a label that floats
            floatingLabelBehavior: empty ? FloatingLabelBehavior.always : null,
            prefixIcon: widget.leadingIcon,
            suffixIcon: const Icon(Icons.arrow_drop_down_rounded),
            border: const OutlineInputBorder(borderRadius: _radius),
          ),
          child: Text(value.text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
