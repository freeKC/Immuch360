import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';

/// ViewIntentHostApi on the computers. The files given to the program (its command line, "Open with", a drop, a later
/// start) come as batches of paths and are opened by DesktopOpenFilesHandler (desktop/files/open_files.dart), not as
/// view intents: none is ever pending here.
class DesktopViewIntentHostApi implements ViewIntentHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<ViewIntentPayload?> consumeViewIntent() async => null;
}
