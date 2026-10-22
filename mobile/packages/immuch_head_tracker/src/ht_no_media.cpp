// The sources of frames on a system without Media Foundation (the gcc builds of test_native/): no camera and no file,
// only ht_process_frame.

#include "ht_tracker.h"

namespace ht {

int32_t ListCameras(std::string* json) {
  (void)json;
  return HT_E_NO_MEDIA_FOUNDATION;
}

int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source) {
  (void)tracker;
  (void)id;
  (void)source;
  return HT_E_NO_MEDIA_FOUNDATION;
}

int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source) {
  (void)tracker;
  (void)path;
  (void)source;
  return HT_E_NO_MEDIA_FOUNDATION;
}

}  // namespace ht
