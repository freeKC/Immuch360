// The face detector DLLs (face_detect.h): libfacedetection behind a C interface. Built twice by windows/CMakeLists.txt,
// with FD_BUILD 2 and the AVX2 code of the library (/arch:AVX2, _ENABLE_AVX2), and with FD_BUILD 1 and its plain C++.

#include "face_detect.h"

#include <mutex>
#include <vector>

#include "facedetectcnn.h"

#ifndef FD_BUILD
#error "FD_BUILD must be 1 (plain) or 2 (AVX2)"
#endif

namespace {

std::mutex& DetectMutex() {
  static std::mutex mutex;
  return mutex;
}

}  // namespace

FD_API int32_t fd_build(void) { return FD_BUILD; }

FD_API int32_t fd_detect(const uint8_t* grey, int32_t width, int32_t height, int32_t stride, FdFace* faces,
                         int32_t max_faces) {
  if (grey == nullptr || width < 16 || height < 16 || width > 4096 || height > 4096 || stride < width ||
      (faces == nullptr && max_faces > 0) || max_faces < 0) {
    return -1;
  }
  std::lock_guard<std::mutex> lock(DetectMutex());
  // libfacedetection takes a BGR image; the network was trained on colour, a grey picture in its three channels is
  // what a grey camera would give it
  static std::vector<unsigned char> bgr;
  static std::vector<unsigned char> results;
  const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
  bgr.resize(pixels * 3);
  results.resize(FACEDETECTION_RESULT_BUFFER_SIZE);
  for (int32_t row = 0; row < height; row++) {
    const uint8_t* source = grey + static_cast<size_t>(row) * static_cast<size_t>(stride);
    unsigned char* target = bgr.data() + static_cast<size_t>(row) * static_cast<size_t>(width) * 3;
    for (int32_t column = 0; column < width; column++) {
      target[0] = target[1] = target[2] = source[column];
      target += 3;
    }
  }
  int* answer = facedetect_cnn(results.data(), bgr.data(), width, height, width * 3);
  if (answer == nullptr) {
    return 0;
  }
  const int32_t found = answer[0] < max_faces ? answer[0] : max_faces;
  for (int32_t i = 0; i < found; i++) {
    const short* p = reinterpret_cast<const short*>(answer + 1) + FACEDETECTION_RESULT_STRIDE_SHORTS * i;
    FdFace& face = faces[i];
    face.score = p[0];
    face.x = p[1];
    face.y = p[2];
    face.width = p[3];
    face.height = p[4];
    for (int landmark = 0; landmark < 10; landmark++) {
      face.landmarks[landmark] = p[5 + landmark];
    }
  }
  return found;
}
