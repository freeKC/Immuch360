import 'package:immich_mobile/domain/utils/event_stream.dart';

// Timeline Events
class TimelineReloadEvent extends Event {
  const TimelineReloadEvent();
}

class ScrollToTopEvent extends Event {
  const ScrollToTopEvent();
}

class ScrollToDateEvent extends Event {
  final DateTime date;

  const ScrollToDateEvent(this.date);
}

// Asset Viewer Events
class ViewerShowDetailsEvent extends Event {
  const ViewerShowDetailsEvent();
}

/// Closes the details of the asset viewer: Back and the info key of a remote control, which has no swipe
class ViewerHideDetailsEvent extends Event {
  const ViewerHideDetailsEvent();
}

// Multi-Select Events
class MultiSelectToggleEvent extends Event {
  final bool isEnabled;
  const MultiSelectToggleEvent(this.isEnabled);
}

// Map Events
class MapMarkerReloadEvent extends Event {
  const MapMarkerReloadEvent();
}
