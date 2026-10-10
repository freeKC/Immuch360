import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('TvTextEntry');

/// A text field typed in through the native text dialog of the TV (TvApi.editText) in TV mode: the Gboard TV keyboard
/// cannot be driven with the remote in a Flutter text field (Flutter issue 177360), and the arrows get stuck in one.
/// [child] is the field, still drawing the value, the dots of a password and the errors of its form, but never focused
/// nor touched in TV mode: OK on it opens the dialog, whose text goes into [controller] and [onSubmitted]. Out of TV
/// mode, [child] as it is.
class TvTextEntry extends ConsumerStatefulWidget {
  const TvTextEntry({
    super.key,
    required this.controller,
    required this.label,
    required this.kind,
    this.onSubmitted,
    required this.child,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController controller;

  /// The title of the dialog, the label of the field
  final String label;
  final TvTextKind kind;

  /// Called with the text of the dialog, so that the chains of the fields go on (the address, then the next field)
  final ValueChanged<String>? onSubmitted;
  final Widget child;

  /// In TV mode only: the entry takes the focus by itself (the first item of a page)
  final bool autofocus;

  /// In TV mode only: the focus of the entry, for the field before it to move the focus here once typed in
  final FocusNode? focusNode;

  @override
  ConsumerState<TvTextEntry> createState() => _TvTextEntryState();
}

class _TvTextEntryState extends ConsumerState<TvTextEntry> {
  bool _editing = false;

  Future<void> _edit() async {
    if (_editing) {
      return;
    }
    _editing = true;
    final String? text;
    try {
      text = await ref
          .read(tvApiProvider)
          .editText(
            TvTextRequest(
              title: widget.label,
              // A password is typed again, never shown in the dialog
              text: widget.kind == TvTextKind.password ? '' : widget.controller.text,
              kind: widget.kind,
              okLabel: context.t.ok,
              cancelLabel: context.t.cancel,
            ),
          );
    } catch (error, stackTrace) {
      _log.warning('The text dialog failed', error, stackTrace);
      return;
    } finally {
      _editing = false;
    }
    if (text == null || !mounted) {
      return;
    }
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onSubmitted?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(tvModeProvider)) {
      return widget.child;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RemoteFocusable(
          onTap: () => unawaited(_edit()),
          autofocus: widget.autofocus,
          focusNode: widget.focusNode,
          // A field is as wide as the page: the focus ring tells the focus, a scale would push it past the edges
          focusScale: 1,
          // Room for the floating label inside the focus: the ring, drawn around the focus, passes above the label
          // rather than across it
          child: Padding(
            padding: EdgeInsets.only(top: _floatingLabelRise(context)),
            child: ExcludeFocus(child: AbsorbPointer(child: widget.child)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Text(
            context.t.tv_text_entry_hint,
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// How far the floating label of an outlined field rises above the field: InputDecorator draws it at three quarters of
/// the font size of the field (bodyLarge), its line as high as that size, centred on the top line of the outline. 6 dp
/// at 16 sp. The focus ring of a TV, drawn a few dp around the focused widget, crossed the label (Name, Port, Email).
double _floatingLabelRise(BuildContext context) {
  final fontSize = Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16;
  return (MediaQuery.textScalerOf(context).scale(fontSize) * 0.75 / 2).ceilToDouble();
}
