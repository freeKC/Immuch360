import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';

class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.hintText,
    this.autofocus = false,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside,
    this.contentPadding = const EdgeInsets.only(left: 24),
    this.prefixIcon,
    this.suffixIcon,
    this.filled = false,
  });

  final FocusNode? focusNode;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;
  final void Function(PointerDownEvent)? onTapOutside;
  final TextEditingController? controller;
  final String hintText;
  final EdgeInsetsGeometry contentPadding;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool autofocus;
  final bool filled;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  /// The text of the native dialog of a TV goes through a controller: this one when the caller gave none
  TextEditingController? _ownController;

  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  /// What the native dialog of a TV returns: setting the text of the controller does not call onChanged
  void _onTyped(String text) {
    widget.onChanged?.call(text);
    widget.onSubmitted?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    return TvTextEntry(
      controller: _controller,
      label: widget.hintText,
      kind: TvTextKind.text,
      autofocus: widget.autofocus,
      onSubmitted: _onTyped,
      child: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onChanged: widget.onChanged,
        onTapOutside: widget.onTapOutside ?? (_) => widget.focusNode?.unfocus(),
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          contentPadding: widget.contentPadding,
          filled: widget.filled,
          fillColor: context.primaryColor.withValues(alpha: 0.1),
          hintStyle: context.textTheme.bodyLarge?.copyWith(color: context.themeData.colorScheme.onSurfaceSecondary),
          border: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            borderSide: BorderSide(color: context.colorScheme.surfaceDim),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            borderSide: BorderSide(color: context.colorScheme.surfaceContainer),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            borderSide: BorderSide(color: context.colorScheme.surfaceDim),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            borderSide: BorderSide(color: context.colorScheme.primary.withAlpha(100)),
          ),
          prefixIcon: widget.prefixIcon,
          suffixIcon: widget.suffixIcon,
          hintText: widget.hintText,
        ),
      ),
    );
  }
}
