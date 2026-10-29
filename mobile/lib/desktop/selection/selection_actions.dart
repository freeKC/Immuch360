// The actions of the bottom sheet of a selection on a computer: "Upload to Immich" first, since sending the photos and
// videos of this computer to the server is what a selection is most often made for here, and "Make 3D (AI)" of the
// photos of the selection last (lib/desktop/ai/ui/conversion_dialog.dart). The phones keep the sheets as they are.

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/upload.action.dart';

/// The [actions] of the bottom sheet of a selection, in their order on a phone; on a computer, "Upload to Immich" first
/// and "Make 3D (AI)" added last
List<Widget> withDesktopSelectionActions(List<Widget> actions) {
  if (!CurrentPlatform.isDesktop) {
    return [...actions];
  }
  bool isUpload(Widget action) => action is ActionColumnButton && action.action is UploadAction;
  return [
    ...actions.where(isUpload),
    ...actions.whereNot(isUpload),
    const DesktopMakeImmersiveButton(source: ActionSource.timeline),
  ];
}
