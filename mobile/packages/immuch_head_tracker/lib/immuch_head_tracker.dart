/// The head tracker of Spatial 2.5D on Windows (see README.md): the webcam through Media Foundation, faces found by
/// libfacedetection on the computer, and the phones' filter and viewpoint. Imported under mobile/lib/desktop only.
library;

export 'package:immuch_head_tracker/src/head_camera.dart';
export 'package:immuch_head_tracker/src/head_sample.dart';
export 'package:immuch_head_tracker/src/head_tracker.dart';
export 'package:immuch_head_tracker/src/head_viewpoint.dart';
export 'package:immuch_head_tracker/src/licence.dart';
export 'package:immuch_head_tracker/src/native_head_tracker.dart'
    show NativeHeadTracker, fourccText, headTrackerApiVersion;
export 'package:immuch_head_tracker/src/one_euro_filter.dart';
