import 'package:flutter/material.dart';
import 'package:immich_mobile/widgets/search/search_filter/filter_bottom_sheet_scaffold.dart';

Future<T> showFilterBottomSheet<T>({
  required BuildContext context,
  required Widget child,
  bool isScrollControlled = false,
  bool isDismissible = true,
}) async {
  // On a directional-control device, short bottom sheets can clip the Apply/Clear
  // buttons, or leave no room to navigate their form fields. Reserve 80% of the
  // screen for the shared TV filter layout. The People/Tags sheets already supply
  // a FractionallySizedBox and must not be wrapped again. A sheet without the
  // action rail (Camera) has its buttons under its fields and keeps its own height.
  final tv = MediaQuery.navigationModeOf(context) == NavigationMode.directional;
  final tvChild = tv && child is FilterBottomSheetScaffold && child.tvActionRail
      ? FractionallySizedBox(heightFactor: 0.8, child: child)
      : child;

  return await showModalBottomSheet(
    context: context,
    isScrollControlled: isScrollControlled || tv,
    useSafeArea: false,
    isDismissible: isDismissible,
    showDragHandle: isDismissible,
    builder: (BuildContext context) => tvChild,
  );
}
