// The fake cameras of the tests, in every build: the build machines have no webcam, so a recorded clip or a recorded
// landmark track goes through the same thread, sample path and callback as a webcam would (ht_api.h).
//
//   y4m:<path>    the luma planes of a YUV4MPEG2 file (colour space mono, 420, 422 or 444, 8 bits), one frame every
//                 1 / frame rate, analysed by the detector like a webcam's frames
//   track:<path>  a recorded landmark track: one line per frame, "time_us score eye_x eye_y eye_distance ..." (a group
//                 of four numbers per face, none for a frame without a face; commas or spaces; # starts a comment),
//                 played at its own times through the face choice, the states and the filter
//
// The end of the file stops the session with HT_E_DEVICE_LOST, as a camera unplugged would.

#ifdef _WIN32
// fopen, sscanf: the files are the tests' own
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#endif

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

#include "ht_tracker.h"

namespace ht {

namespace {

bool StartsWith(const std::string& text, const char* prefix) { return text.compare(0, strlen(prefix), prefix) == 0; }

FILE* OpenRead(const std::string& path) {
#ifdef _WIN32
  // The path is UTF-8
  const int length = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
  if (length <= 0) {
    return nullptr;
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &wide[0], length);
  return _wfopen(wide.c_str(), L"rb");
#else
  return fopen(path.c_str(), "rb");
#endif
}

// The header of a YUV4MPEG2 file
struct Y4mHeader {
  int32_t width = 0;
  int32_t height = 0;
  int32_t fps_numerator = 25;
  int32_t fps_denominator = 1;
  // The bytes of the chroma planes after the luma plane
  size_t chroma = 0;
};

bool ReadLine(FILE* file, std::string* line) {
  line->clear();
  int c;
  while ((c = fgetc(file)) != EOF) {
    if (c == '\n') {
      return true;
    }
    line->push_back(static_cast<char>(c));
    if (line->size() > 4096) {
      return false;
    }
  }
  return !line->empty();
}

bool ParseY4mHeader(const std::string& line, Y4mHeader* header) {
  if (!StartsWith(line, "YUV4MPEG2")) {
    return false;
  }
  std::string colour = "420";
  size_t at = 9;
  while (at < line.size()) {
    while (at < line.size() && line[at] == ' ') {
      at++;
    }
    size_t end = line.find(' ', at);
    if (end == std::string::npos) {
      end = line.size();
    }
    const std::string token = line.substr(at, end - at);
    at = end;
    if (token.empty()) {
      continue;
    }
    switch (token[0]) {
      case 'W':
        header->width = atoi(token.c_str() + 1);
        break;
      case 'H':
        header->height = atoi(token.c_str() + 1);
        break;
      case 'F':
        if (sscanf(token.c_str() + 1, "%d:%d", &header->fps_numerator, &header->fps_denominator) != 2) {
          return false;
        }
        break;
      case 'C':
        colour = token.substr(1);
        break;
      default:
        break;
    }
  }
  if (header->width < 16 || header->height < 16 || header->width > 8192 || header->height > 8192 ||
      header->fps_numerator <= 0 || header->fps_denominator <= 0) {
    return false;
  }
  const size_t w = static_cast<size_t>(header->width), h = static_cast<size_t>(header->height);
  if (colour == "mono") {
    header->chroma = 0;
  } else if (StartsWith(colour, "420")) {
    header->chroma = 2 * ((w + 1) / 2) * ((h + 1) / 2);
  } else if (colour == "422") {
    header->chroma = 2 * ((w + 1) / 2) * h;
  } else if (colour == "444") {
    header->chroma = 2 * w * h;
  } else {
    // 10 bit and alpha formats are not for the tests
    return false;
  }
  return true;
}

void RunY4m(std::shared_ptr<ThreadState> state, std::string path) {
  FILE* file = OpenRead(path);
  if (file == nullptr) {
    state->Fail(HT_E_NO_CAMERA);
    return;
  }
  std::string line;
  Y4mHeader header;
  if (!ReadLine(file, &line) || !ParseY4mHeader(line, &header)) {
    fclose(file);
    state->Fail(HT_E_FORMAT);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state->shared->mutex);
    state->shared->info.width = header.width;
    state->shared->info.height = header.height;
    state->shared->info.fps_numerator = header.fps_numerator;
    state->shared->info.fps_denominator = header.fps_denominator;
    state->shared->info.native_fourcc = 0x30303859;  // "Y800"
  }
  std::vector<uint8_t> luma(static_cast<size_t>(header.width) * static_cast<size_t>(header.height));
  std::vector<uint8_t> skip(header.chroma);
  const int64_t start = NowUs();
  for (int64_t index = 0; !state->stop; index++) {
    if (!ReadLine(file, &line) || !StartsWith(line, "FRAME") || fread(luma.data(), 1, luma.size(), file) != luma.size() ||
        (header.chroma > 0 && fread(skip.data(), 1, skip.size(), file) != skip.size())) {
      fclose(file);
      state->Fail(HT_E_DEVICE_LOST);
      return;
    }
    // Delivered when a camera would have: frame [index] at index / rate after the start
    const int64_t due = start + index * 1000000 * header.fps_denominator / header.fps_numerator;
    const int64_t wait = due - NowUs();
    if (wait > 0 && state->WaitStop(std::chrono::microseconds(wait))) {
      break;
    }
    LumaPlane plane;
    plane.data = luma.data();
    plane.width = header.width;
    plane.height = header.height;
    plane.stride = header.width;
    state->Frame(plane, NowUs());
  }
  fclose(file);
}

// One line of a track: its time and its faces; false for a line to skip (empty, a comment, unreadable)
bool ParseTrackLine(const std::string& line, int64_t* time_us, std::vector<HtFace>* faces) {
  faces->clear();
  std::vector<double> numbers;
  const char* at = line.c_str();
  while (*at != '\0' && *at != '#') {
    if (*at == ' ' || *at == ',' || *at == '\t' || *at == '\r') {
      at++;
      continue;
    }
    char* end = nullptr;
    const double value = strtod(at, &end);
    if (end == at) {
      return false;
    }
    numbers.push_back(value);
    at = end;
  }
  if (numbers.empty() || (numbers.size() - 1) % 4 != 0) {
    return false;
  }
  *time_us = static_cast<int64_t>(numbers[0]);
  for (size_t i = 1; i + 3 < numbers.size(); i += 4) {
    HtFace face{};
    face.score = static_cast<int32_t>(numbers[i]);
    face.eye_x = numbers[i + 1];
    face.eye_y = numbers[i + 2];
    face.eye_distance = numbers[i + 3];
    faces->push_back(face);
  }
  return true;
}

void RunTrack(std::shared_ptr<ThreadState> state, std::string path) {
  FILE* file = OpenRead(path);
  if (file == nullptr) {
    state->Fail(HT_E_NO_CAMERA);
    return;
  }
  std::string line;
  std::vector<HtFace> faces;
  int64_t first = -1;
  const int64_t start = NowUs();
  bool any = false;
  while (!state->stop) {
    if (!ReadLine(file, &line)) {
      break;
    }
    int64_t time_us = 0;
    if (!ParseTrackLine(line, &time_us, &faces)) {
      continue;
    }
    if (first < 0) {
      first = time_us;
    }
    const int64_t due = start + (time_us - first);
    const int64_t wait = due - NowUs();
    if (wait > 0 && state->WaitStop(std::chrono::microseconds(wait))) {
      break;
    }
    if (!state->core->CountFrame()) {
      continue;
    }
    HtSample sample;
    state->core->AnalyseFaces(faces.data(), static_cast<int32_t>(faces.size()), NowUs(), &sample);
    sample.frame_width = 640;
    sample.frame_height = 480;
    state->sequence = sample.sequence;
    state->shared->Publish(sample);
    any = true;
  }
  fclose(file);
  if (!state->stop) {
    state->Fail(any ? HT_E_DEVICE_LOST : HT_E_FORMAT);
  }
}

}  // namespace

bool IsFakeCamera(const std::string& id) { return StartsWith(id, "y4m:") || StartsWith(id, "track:"); }

int32_t OpenFakeCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source) {
  const bool y4m = StartsWith(id, "y4m:");
  const std::string path = id.substr(y4m ? 4 : 6);
  if (path.empty()) {
    return HT_E_ARGUMENT;
  }
  auto state = NewThreadState(tracker, id);
  if (y4m) {
    *source = std::make_unique<ThreadSource>(state, [path](std::shared_ptr<ThreadState> s) { RunY4m(s, path); });
  } else {
    *source = std::make_unique<ThreadSource>(state, [path](std::shared_ptr<ThreadState> s) { RunTrack(s, path); });
  }
  return HT_OK;
}

}  // namespace ht
