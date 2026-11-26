// The webcams of Linux for the head tracker: V4L2 directly, on a capture thread of the library.
//
// - The capture nodes are /dev/video*, opened through the logind "uaccess" ACL that the desktop session gives the user
//   on the webcams (no group to join); a node that answers EACCES gives HT_E_ACCESS_DENIED.
// - Only uncompressed formats: YUYV, UYVY, NV12, NV21, YU12, YV12 (and GREY, Y16 when the caller did not ask for colour
//   only). Nearly every UVC webcam offers YUYV at 640 x 480 at 30 fps; one that offers MJPEG only gives HT_E_FORMAT,
//   since no JPEG decoder is shipped.
// - A node whose formats are all GREY or Y16 is an infrared sensor (Windows Hello style): listed with "grey", never the
//   default, and refused with HT_E_GREY_ONLY under HT_FLAG_COLOUR_ONLY.
// - While tracking, the camera's "exposure, dynamic framerate" control (V4L2_CID_EXPOSURE_AUTO_PRIORITY) is set to 0,
//   so that low light does not drop the frame rate, and given back when the session stops.
// - Memory mapped buffers, four of them; only the luma of the newest frame is read, in place, and the buffer goes back
//   to the driver at once. Nothing is copied out, nothing is written anywhere.
// - EBUSY gives HT_E_CAMERA_BUSY; ENODEV or EIO while streaming (the webcam unplugged) HT_E_DEVICE_LOST.

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <vector>

#include "ht_tracker.h"

namespace ht {

namespace {

int Xioctl(int fd, unsigned long request, void* argument) {
  int result;
  do {
    result = ioctl(fd, request, argument);
  } while (result == -1 && errno == EINTR);
  return result;
}

int32_t StatusOfErrno(int error) {
  switch (error) {
    case EACCES:
    case EPERM:
      return HT_E_ACCESS_DENIED;
    case EBUSY:
      return HT_E_CAMERA_BUSY;
    case ENOENT:
    case ENXIO:
      return HT_E_NO_CAMERA;
    case ENODEV:
    case EIO:
      return HT_E_DEVICE_LOST;
    default:
      return HT_E_FAILED;
  }
}

bool IsGrey(uint32_t format) { return format == V4L2_PIX_FMT_GREY || format == V4L2_PIX_FMT_Y16; }

// How the luma of a format is read, false for a format the tracker cannot read
bool LumaLayout(uint32_t format, int32_t* pixel_step, int32_t* offset) {
  switch (format) {
    case V4L2_PIX_FMT_YUYV:
    case V4L2_PIX_FMT_YVYU:
      *pixel_step = 2;
      *offset = 0;
      return true;
    case V4L2_PIX_FMT_UYVY:
    case V4L2_PIX_FMT_VYUY:
      *pixel_step = 2;
      *offset = 1;
      return true;
    case V4L2_PIX_FMT_NV12:
    case V4L2_PIX_FMT_NV21:
    case V4L2_PIX_FMT_YUV420:
    case V4L2_PIX_FMT_YVU420:
    case V4L2_PIX_FMT_GREY:
      *pixel_step = 1;
      *offset = 0;
      return true;
    case V4L2_PIX_FMT_Y16:
      // Little endian 16 bits: the high byte
      *pixel_step = 2;
      *offset = 1;
      return true;
    default:
      return false;
  }
}

// The preference among the readable formats: the cheapest luma first
int FormatRank(uint32_t format) {
  switch (format) {
    case V4L2_PIX_FMT_NV12:
    case V4L2_PIX_FMT_NV21:
    case V4L2_PIX_FMT_YUV420:
    case V4L2_PIX_FMT_YVU420:
      return 0;
    case V4L2_PIX_FMT_YUYV:
    case V4L2_PIX_FMT_YVYU:
    case V4L2_PIX_FMT_UYVY:
    case V4L2_PIX_FMT_VYUY:
      return 1;
    case V4L2_PIX_FMT_GREY:
      return 2;
    default:
      return 3;
  }
}

struct NodeFormats {
  std::vector<uint32_t> formats;
  bool any_colour = false;
  bool any_grey = false;
};

NodeFormats ListFormats(int fd) {
  NodeFormats result;
  for (uint32_t index = 0; index < 64; index++) {
    v4l2_fmtdesc description;
    memset(&description, 0, sizeof(description));
    description.index = index;
    description.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Xioctl(fd, VIDIOC_ENUM_FMT, &description) != 0) {
      break;
    }
    result.formats.push_back(description.pixelformat);
    if (IsGrey(description.pixelformat)) {
      result.any_grey = true;
    } else {
      result.any_colour = true;
    }
  }
  return result;
}

// A video capture node (not a metadata node of the same webcam)
bool IsCaptureNode(int fd, v4l2_capability* capability) {
  memset(capability, 0, sizeof(*capability));
  if (Xioctl(fd, VIDIOC_QUERYCAP, capability) != 0) {
    return false;
  }
  const uint32_t caps =
      (capability->capabilities & V4L2_CAP_DEVICE_CAPS) != 0 ? capability->device_caps : capability->capabilities;
  return (caps & V4L2_CAP_VIDEO_CAPTURE) != 0 && (caps & V4L2_CAP_STREAMING) != 0;
}

void AppendJsonString(std::string* json, const std::string& text) {
  json->push_back('"');
  for (const char c : text) {
    const unsigned char u = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
      json->push_back('\\');
      json->push_back(c);
    } else if (u < 0x20) {
      char escaped[8];
      snprintf(escaped, sizeof(escaped), "\\u%04x", u);
      json->append(escaped);
    } else {
      json->push_back(c);
    }
  }
  json->push_back('"');
}

// The /dev/video* nodes in number order
std::vector<std::string> VideoNodes() {
  std::vector<std::pair<int, std::string>> found;
  for (int number = 0; number < 64; number++) {
    const std::string path = "/dev/video" + std::to_string(number);
    struct stat info;
    if (stat(path.c_str(), &info) == 0 && S_ISCHR(info.st_mode)) {
      found.emplace_back(number, path);
    }
  }
  std::vector<std::string> nodes;
  for (const auto& node : found) {
    nodes.push_back(node.second);
  }
  return nodes;
}

struct Buffer {
  void* start = MAP_FAILED;
  size_t length = 0;
};

// The capture of one node, from open to close
class Capture {
 public:
  ~Capture() { Close(); }

  // Opens [path], picks a format near the options and starts streaming. HT_OK or an error.
  int32_t Open(const std::string& path, const HtOptions& options, Shared* shared) {
    if (path.compare(0, 5, "/dev/") != 0) {
      return HT_E_NO_CAMERA;
    }
    fd_ = open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd_ < 0) {
      return StatusOfErrno(errno);
    }
    v4l2_capability capability;
    if (!IsCaptureNode(fd_, &capability)) {
      return HT_E_NO_CAMERA;
    }
    const NodeFormats formats = ListFormats(fd_);
    if ((options.flags & HT_FLAG_COLOUR_ONLY) != 0 && formats.any_grey && !formats.any_colour) {
      return HT_E_GREY_ONLY;
    }
    uint32_t chosen = 0;
    int best = 99;
    for (const uint32_t format : formats.formats) {
      int32_t step = 0, offset = 0;
      if (!LumaLayout(format, &step, &offset)) {
        continue;
      }
      if ((options.flags & HT_FLAG_COLOUR_ONLY) != 0 && IsGrey(format)) {
        continue;
      }
      const int rank = FormatRank(format);
      if (rank < best) {
        best = rank;
        chosen = format;
      }
    }
    if (chosen == 0) {
      // MJPEG or H.264 only: no decoder is shipped
      return HT_E_FORMAT;
    }
    v4l2_format format;
    memset(&format, 0, sizeof(format));
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    format.fmt.pix.width = static_cast<uint32_t>(options.width);
    format.fmt.pix.height = static_cast<uint32_t>(options.height);
    format.fmt.pix.pixelformat = chosen;
    format.fmt.pix.field = V4L2_FIELD_NONE;
    if (Xioctl(fd_, VIDIOC_S_FMT, &format) != 0) {
      return errno == EBUSY ? HT_E_CAMERA_BUSY : HT_E_FORMAT;
    }
    if (!LumaLayout(format.fmt.pix.pixelformat, &step_, &offset_)) {
      return HT_E_FORMAT;
    }
    width_ = static_cast<int32_t>(format.fmt.pix.width);
    height_ = static_cast<int32_t>(format.fmt.pix.height);
    stride_ = static_cast<int32_t>(format.fmt.pix.bytesperline);
    if (stride_ < width_ * (step_ == 2 ? 2 : 1)) {
      stride_ = width_ * (step_ == 2 ? 2 : 1);
    }
    if (width_ < 16 || height_ < 16) {
      return HT_E_FORMAT;
    }
    // The frame rate asked for, when the driver takes it
    v4l2_streamparm parameters;
    memset(&parameters, 0, sizeof(parameters));
    parameters.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Xioctl(fd_, VIDIOC_G_PARM, &parameters) == 0 &&
        (parameters.parm.capture.capability & V4L2_CAP_TIMEPERFRAME) != 0) {
      parameters.parm.capture.timeperframe.numerator = 1;
      parameters.parm.capture.timeperframe.denominator = static_cast<uint32_t>(options.fps);
      Xioctl(fd_, VIDIOC_S_PARM, &parameters);
    }
    uint32_t fps_numerator = 0, fps_denominator = 0;
    if (Xioctl(fd_, VIDIOC_G_PARM, &parameters) == 0 && parameters.parm.capture.timeperframe.numerator != 0) {
      fps_numerator = parameters.parm.capture.timeperframe.denominator;
      fps_denominator = parameters.parm.capture.timeperframe.numerator;
    }
    // A steady frame rate in low light: the dynamic frame rate off for the session
    v4l2_control control;
    memset(&control, 0, sizeof(control));
    control.id = V4L2_CID_EXPOSURE_AUTO_PRIORITY;
    if (Xioctl(fd_, VIDIOC_G_CTRL, &control) == 0) {
      saved_priority_ = control.value;
      has_priority_ = true;
      if (control.value != 0) {
        control.value = 0;
        Xioctl(fd_, VIDIOC_S_CTRL, &control);
      }
    }
    v4l2_requestbuffers request;
    memset(&request, 0, sizeof(request));
    request.count = 4;
    request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    request.memory = V4L2_MEMORY_MMAP;
    if (Xioctl(fd_, VIDIOC_REQBUFS, &request) != 0 || request.count < 2) {
      return errno == EBUSY ? HT_E_CAMERA_BUSY : HT_E_FAILED;
    }
    buffers_.resize(request.count);
    for (uint32_t i = 0; i < request.count; i++) {
      v4l2_buffer buffer;
      memset(&buffer, 0, sizeof(buffer));
      buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      buffer.memory = V4L2_MEMORY_MMAP;
      buffer.index = i;
      if (Xioctl(fd_, VIDIOC_QUERYBUF, &buffer) != 0) {
        return HT_E_FAILED;
      }
      buffers_[i].length = buffer.length;
      buffers_[i].start = mmap(nullptr, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, buffer.m.offset);
      if (buffers_[i].start == MAP_FAILED) {
        return HT_E_FAILED;
      }
      if (Xioctl(fd_, VIDIOC_QBUF, &buffer) != 0) {
        return HT_E_FAILED;
      }
    }
    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Xioctl(fd_, VIDIOC_STREAMON, &type) != 0) {
      return errno == EBUSY ? HT_E_CAMERA_BUSY : StatusOfErrno(errno);
    }
    streaming_ = true;
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->info.width = width_;
    shared->info.height = height_;
    shared->info.fps_numerator = static_cast<int32_t>(fps_numerator);
    shared->info.fps_denominator = static_cast<int32_t>(fps_denominator);
    shared->info.native_fourcc = format.fmt.pix.pixelformat;
    shared->info.framing = HT_FRAMING_ABSENT;
    return HT_OK;
  }

  // Waits for the next frame (or the wake pipe) and hands its luma to [frame]. HT_OK, 1 when woken, or an error.
  template <typename Frame>
  int32_t Next(int wake_fd, Frame frame) {
    pollfd polls[2];
    polls[0].fd = fd_;
    polls[0].events = POLLIN;
    polls[0].revents = 0;
    polls[1].fd = wake_fd;
    polls[1].events = POLLIN;
    polls[1].revents = 0;
    const int ready = poll(polls, 2, 2000);
    if (ready < 0) {
      return errno == EINTR ? HT_OK : HT_E_FAILED;
    }
    if ((polls[1].revents & POLLIN) != 0) {
      return 1;
    }
    if (ready == 0) {
      // No frame for two seconds: a camera covered or very dark still sends frames, so it is gone
      return HT_E_DEVICE_LOST;
    }
    if ((polls[0].revents & (POLLERR | POLLHUP)) != 0) {
      return HT_E_DEVICE_LOST;
    }
    v4l2_buffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buffer.memory = V4L2_MEMORY_MMAP;
    if (Xioctl(fd_, VIDIOC_DQBUF, &buffer) != 0) {
      return errno == EAGAIN ? HT_OK : StatusOfErrno(errno == EINVAL ? ENODEV : errno);
    }
    if ((buffer.flags & V4L2_BUF_FLAG_ERROR) == 0 && buffer.index < buffers_.size() &&
        buffer.bytesused >= static_cast<uint32_t>(stride_) * static_cast<uint32_t>(height_ - 1) +
                                static_cast<uint32_t>(width_ * step_)) {
      LumaPlane plane;
      plane.data = static_cast<const uint8_t*>(buffers_[buffer.index].start) + offset_;
      plane.width = width_;
      plane.height = height_;
      plane.stride = stride_;
      plane.pixel_step = step_;
      frame(plane);
    }
    if (Xioctl(fd_, VIDIOC_QBUF, &buffer) != 0) {
      return StatusOfErrno(errno == EINVAL ? ENODEV : errno);
    }
    return HT_OK;
  }

  void Close() {
    if (fd_ < 0) {
      return;
    }
    if (streaming_) {
      v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      Xioctl(fd_, VIDIOC_STREAMOFF, &type);
      streaming_ = false;
    }
    if (has_priority_) {
      v4l2_control control;
      memset(&control, 0, sizeof(control));
      control.id = V4L2_CID_EXPOSURE_AUTO_PRIORITY;
      control.value = saved_priority_;
      Xioctl(fd_, VIDIOC_S_CTRL, &control);
    }
    for (Buffer& buffer : buffers_) {
      if (buffer.start != MAP_FAILED) {
        munmap(buffer.start, buffer.length);
      }
    }
    buffers_.clear();
    close(fd_);
    fd_ = -1;
  }

 private:
  int fd_ = -1;
  bool streaming_ = false;
  bool has_priority_ = false;
  int32_t saved_priority_ = 0;
  std::vector<Buffer> buffers_;
  int32_t width_ = 0;
  int32_t height_ = 0;
  int32_t stride_ = 0;
  int32_t step_ = 1;
  int32_t offset_ = 0;
};

void RunCamera(std::shared_ptr<ThreadState> state, int wake_read) {
  Capture capture;
  const int32_t opened = capture.Open(state->id, state->options, state->shared.get());
  if (opened != HT_OK) {
    capture.Close();
    state->Fail(opened);
    return;
  }
  while (!state->stop) {
    const int32_t result = capture.Next(wake_read, [&state](const LumaPlane& plane) { state->Frame(plane, NowUs()); });
    if (result == 1) {
      break;
    }
    if (result < 0) {
      capture.Close();
      if (!state->stop) {
        state->Fail(result);
      }
      return;
    }
  }
  // Released before the thread ends: ht_close returns with the light off
  capture.Close();
}

}  // namespace

int32_t ListCameras(std::string* json) {
  json->assign("[");
  bool first = true;
  for (const std::string& path : VideoNodes()) {
    const int fd = open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
      continue;
    }
    v4l2_capability capability;
    if (!IsCaptureNode(fd, &capability)) {
      close(fd);
      continue;
    }
    const NodeFormats formats = ListFormats(fd);
    close(fd);
    if (formats.formats.empty()) {
      continue;
    }
    const std::string name(reinterpret_cast<const char*>(capability.card),
                           strnlen(reinterpret_cast<const char*>(capability.card), sizeof(capability.card)));
    const std::string driver(reinterpret_cast<const char*>(capability.driver),
                             strnlen(reinterpret_cast<const char*>(capability.driver), sizeof(capability.driver)));
    if (!first) {
      json->push_back(',');
    }
    first = false;
    json->append("{\"id\":");
    AppendJsonString(json, path);
    json->append(",\"name\":");
    AppendJsonString(json, name.empty() ? path : name);
    json->append(",\"panel\":\"unknown\",\"virtual\":");
    json->append(driver == "v4l2 loopback" ? "true" : "false");
    json->append(",\"grey\":");
    json->append(formats.any_grey && !formats.any_colour ? "true" : "false");
    json->push_back('}');
  }
  json->push_back(']');
  return HT_OK;
}

int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source) {
  if (id.compare(0, 5, "file:") == 0) {
    // The tests play files through the fake cameras ("y4m:") on Linux: no system reader of video files here
    return HT_E_NO_MEDIA_FOUNDATION;
  }
  if (id.empty()) {
    return HT_E_ARGUMENT;
  }
  int pipe_fds[2];
  if (pipe2(pipe_fds, O_CLOEXEC | O_NONBLOCK) != 0) {
    return HT_E_FAILED;
  }
  auto state = NewThreadState(tracker, id);
  const int wake_read = pipe_fds[0], wake_write = pipe_fds[1];
  // The pipe lives as long as the state: the thread may outlive ht_close
  auto pipes = std::shared_ptr<int>(new int[2]{wake_read, wake_write}, [](int* fds) {
    close(fds[0]);
    close(fds[1]);
    delete[] fds;
  });
  state->wake = [pipes]() {
    const char byte = 1;
    ssize_t written = write(pipes.get()[1], &byte, 1);
    (void)written;
  };
  *source = std::make_unique<ThreadSource>(state, [pipes](std::shared_ptr<ThreadState> s) { RunCamera(s, pipes.get()[0]); });
  return HT_OK;
}

int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source) {
  (void)tracker;
  (void)path;
  (void)source;
  // The tests play files through the fake cameras ("y4m:") on Linux
  return HT_E_NO_MEDIA_FOUNDATION;
}

}  // namespace ht
