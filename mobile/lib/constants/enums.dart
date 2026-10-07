enum SortOrder {
  asc,
  desc;

  SortOrder reverse() {
    return this == SortOrder.asc ? SortOrder.desc : SortOrder.asc;
  }
}

enum TextSearchType { context, filename, description, ocr }

enum ActionSource { timeline, viewer }

enum ShareAssetType { original, preview }

enum CleanupStep { selectDate, scan, delete }

enum AssetKeepType { none, photosOnly, videosOnly }

enum AssetDateAggregation { start, end }

enum SlideshowLook { contain, cover, blurredBackground }

enum SlideshowDirection { forward, backward, shuffle }

/// Which file of a server video the players load: the original when this device decodes it, else the server's
/// transcoded stream; always the original, whatever the device; or always the transcoded stream
enum VideoSourcePolicy { preferOriginalWithinDecoder, alwaysOriginal, alwaysTranscoded }

/// The remote control layout (see tvModeProvider): on by itself on Android TV and Google TV, or forced on (a tablet
/// driven by a keyboard or a game pad) or off
enum TvLayoutMode { auto, on, off }

enum PartnerDirection { sharedBy, sharedWith }

enum DevicePermission { photos, videos, storage, mediaLocation }

enum DevicePermissionStatus {
  denied,
  granted,
  limited,
  permanentlyDenied;

  bool get hasAccess => this == granted || this == limited;
}
