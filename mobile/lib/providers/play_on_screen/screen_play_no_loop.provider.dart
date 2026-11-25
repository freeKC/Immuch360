// The Immich video a phone opened on this screen (release 52): it plays once, whatever the Looping setting of the
// device, so that it reaches its end and the phone's slideshow moves on (computers and the Quest window loop by
// default). Set when the screen opens a phone's video, replaced by the next one.

import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The remote id of that video, null while none
final screenPlayNoLoopAssetProvider = StateProvider<String?>((_) => null);
