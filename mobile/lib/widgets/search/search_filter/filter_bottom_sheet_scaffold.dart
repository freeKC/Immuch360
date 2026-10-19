import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// A shared filter sheet. On TV, [tvActionRail] puts the action buttons beside
/// the scrollable filter content so the remote can reach them with one Right.
class FilterBottomSheetScaffold extends StatefulWidget {
  const FilterBottomSheetScaffold({
    super.key,
    required this.child,
    this.onSearch,
    required this.onClear,
    required this.title,
    this.expanded,
    this.tvActionRail = false,
  });

  final bool? expanded;
  final String title;
  final Widget child;
  final Function()? onSearch;
  final Function() onClear;
  final bool tvActionRail;

  @override
  State<FilterBottomSheetScaffold> createState() => _FilterBottomSheetScaffoldState();
}

class _FilterBottomSheetScaffoldState extends State<FilterBottomSheetScaffold> {
  final _contentScope = FocusScopeNode(debugLabel: 'TV filter content');
  final _clearFocus = FocusNode(debugLabel: 'TV filter clear');
  final _applyFocus = FocusNode(debugLabel: 'TV filter apply');
  FocusNode? _lastContentFocus;

  @override
  void dispose() {
    _contentScope.dispose();
    _clearFocus.dispose();
    _applyFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onContentKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }

    // A search text field still needs Left/Right for caret movement.
    final focused = FocusManager.instance.primaryFocus;
    final focusedContext = focused?.context;
    if (focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }

    _lastContentFocus = focused;
    (widget.onSearch == null ? _clearFocus : _applyFocus).requestFocus();
    return KeyEventResult.handled;
  }

  KeyEventResult _onActionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }

    // Return to the same person, even in a long, lazily built list.
    final previous = _lastContentFocus;
    if (previous != null && previous.canRequestFocus && previous.context?.mounted == true) {
      previous.requestFocus();
    } else {
      _contentScope.requestFocus();
    }
    return KeyEventResult.handled;
  }

  Widget _clearButton({required bool tv}) => OutlinedButton(
    focusNode: tv ? _clearFocus : null,
    onPressed: () {
      widget.onClear();
      context.pop();
    },
    child: Text(context.t.clear),
  );

  Widget _applyButton({required bool tv}) => ElevatedButton(
    key: const Key('search_filter_apply'),
    focusNode: tv ? _applyFocus : null,
    onPressed: () {
      widget.onSearch!();
      context.pop();
    },
    child: Text(context.t.search_filter_apply),
  );

  @override
  Widget build(BuildContext context) {
    final tv = widget.tvActionRail && MediaQuery.navigationModeOf(context) == NavigationMode.directional;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(widget.title, style: context.textTheme.headlineSmall),
          ),
          if (tv)
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: FocusScope(
                      node: _contentScope,
                      child: Focus(
                        skipTraversal: true,
                        onKeyEvent: _onContentKey,
                        child: widget.child,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 150,
                      child: Focus(
                        skipTraversal: true,
                        onKeyEvent: _onActionKey,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _clearButton(tv: true),
                            if (widget.onSearch != null) const SizedBox(height: 12),
                            if (widget.onSearch != null) _applyButton(tv: true),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            if (widget.expanded == true) Expanded(child: widget.child) else widget.child,
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _clearButton(tv: false),
                  if (widget.onSearch != null) const SizedBox(width: 8),
                  if (widget.onSearch != null) _applyButton(tv: false),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
