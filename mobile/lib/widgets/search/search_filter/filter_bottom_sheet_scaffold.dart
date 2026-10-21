import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';

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
  /// Around the content in the rail layout: not a focus scope, so that the arrows of a radio button, which TvShell
  /// moves through the traversal policy before this sheet sees them, can leave the content for the rail
  final _content = FocusNode(debugLabel: 'TV filter content', canRequestFocus: false, skipTraversal: true);
  final _clearFocus = FocusNode(debugLabel: 'TV filter clear');
  final _applyFocus = FocusNode(debugLabel: 'TV filter apply');
  FocusNode? _lastContentFocus;

  /// The traversal policy of the content in the rail layout
  late final _contentPolicy = _ContentTraversalPolicy(() => widget.onSearch == null ? _clearFocus : _applyFocus);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_rememberContentFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_rememberContentFocus);
    _content.dispose();
    _clearFocus.dispose();
    _applyFocus.dispose();
    super.dispose();
  }

  /// The item of the content that had the focus last, whatever took the focus to the rail: Right in a list, or an
  /// arrow on a radio button
  void _rememberContentFocus() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.ancestors.contains(_content)) {
      _lastContentFocus = focused;
    }
  }

  /// Right anywhere in the content goes to Apply (Clear when there is no Apply), from any row of a long list
  KeyEventResult _onContentKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    (widget.onSearch == null ? _clearFocus : _applyFocus).requestFocus();
    return KeyEventResult.handled;
  }

  /// Left on the rail goes back to the item the focus came from, even in a long, lazily built list, or to the first
  /// item on screen when that one is gone
  KeyEventResult _onActionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final previous = _lastContentFocus;
    final target = previous != null && previous.canRequestFocus && previous.ancestors.contains(_content)
        ? previous
        : topLeftFocusNode(_content.traversalDescendants);
    if (target == null) {
      return KeyEventResult.ignored;
    }
    target.requestFocus();
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
                    child: FocusTraversalGroup(
                      policy: _contentPolicy,
                      child: Focus(focusNode: _content, onKeyEvent: _onContentKey, child: widget.child),
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

/// The content of the rail layout moves Right to Apply (Clear when there is no Apply) for the moves that never reach
/// [_FilterBottomSheetScaffoldState._onContentKey]: TvShell moves the focus of a radio button through this policy
/// before the sheet sees the key. The nearest button on the right was then Clear for the upper choices, and OK there
/// cleared the filter instead of applying the choice.
class _ContentTraversalPolicy extends ReadingOrderTraversalPolicy {
  _ContentTraversalPolicy(this._railTarget);

  final FocusNode Function() _railTarget;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction != TraversalDirection.right) {
      return super.inDirection(currentNode, direction);
    }
    final target = _railTarget();
    if (!target.canRequestFocus || target.context == null) {
      return super.inDirection(currentNode, direction);
    }
    target.requestFocus();
    return true;
  }
}
