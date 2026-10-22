// The sources of frames on Windows: a webcam or a video file through a Media Foundation source reader, and the list of
// the cameras.
//
// Media Foundation is loaded at run time (LoadLibraryExW from System32, GetProcAddress) rather than linked: a Windows N
// edition without the Media Feature Pack, or a Windows Server without the Media Foundation feature, has no mfplat.dll,
// and a DLL that imports it would not load at all. There the tracker answers HT_E_NO_MEDIA_FOUNDATION and the app shows
// the Media Feature Pack message.
//
// The camera runs on a thread of its own, in the multithreaded apartment, with the source reader in synchronous mode:
// each frame is read there, its luma plane box filtered into a small grey image, the detector run on it, and only the
// sample leaves the thread. The frame buffers go back to Media Foundation at once; nothing is copied elsewhere or
// written to disk.

#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <string.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ht_tracker.h"

namespace ht {

namespace {

// Status codes of mferror.h and winerror.h, written out in case an older SDK lacks one
constexpr HRESULT kAccessDenied = static_cast<HRESULT>(0x80070005L);
constexpr HRESULT kSharingViolation = static_cast<HRESULT>(0x80070020L);
constexpr HRESULT kDeviceInUse = static_cast<HRESULT>(0x80070964L);
constexpr HRESULT kDeviceRemoved = static_cast<HRESULT>(0x80070651L);
constexpr HRESULT kDeviceNotConnected = static_cast<HRESULT>(0x8007048FL);
constexpr HRESULT kGenFailure = static_cast<HRESULT>(0x8007001FL);
constexpr HRESULT kFileNotFound = static_cast<HRESULT>(0x80070002L);
constexpr HRESULT kPathNotFound = static_cast<HRESULT>(0x80070003L);
constexpr HRESULT kRecordingDeviceInvalidated = static_cast<HRESULT>(0xC00D3EA2L);
constexpr HRESULT kRecordingDevicePreempted = static_cast<HRESULT>(0xC00D3EA3L);
constexpr HRESULT kHwMftFailedStartStreaming = static_cast<HRESULT>(0xC00D3704L);
constexpr HRESULT kNoMoreTypes = static_cast<HRESULT>(0xC00D36B9L);
constexpr HRESULT kInvalidMediaType = static_cast<HRESULT>(0xC00D36B4L);
constexpr HRESULT kTopoCodecNotFound = static_cast<HRESULT>(0xC00D5212L);
constexpr HRESULT kUnsupportedByteStream = static_cast<HRESULT>(0xC00D36C4L);
constexpr HRESULT kUnsupportedScheme = static_cast<HRESULT>(0xC00D36C3L);
constexpr HRESULT kInvalidStreamNumber = static_cast<HRESULT>(0xC00D36B3L);

constexpr DWORD kFirstVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);

// MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY and KSCATEGORY_VIDEO_CAMERA (mfidl.h, ksmedia.h): the colour
// cameras. Windows Hello infrared sensors register as KSCATEGORY_SENSOR_CAMERA instead; an infrared camera that shows
// as a video camera all the same is left out of the default choice by its name (lib/src/head_camera.dart).
const GUID kVidcapCategory = {0x77f0ae69, 0xc3bd, 0x4509, {0x94, 0x1d, 0x46, 0x7e, 0x4d, 0x24, 0x89, 0x9e}};
const GUID kKsCategoryVideoCamera = {0xe5323777, 0xf976, 0x4f5b, {0x9b, 0x55, 0xb9, 0x46, 0x99, 0xc4, 0x6e, 0x44}};

// The extended camera controls of ksmedia.h, written out here so that the kernel streaming headers are not needed
const GUID kKsPropertySetExtendedCameraControl = {
    0x1cb79112, 0xc0d2, 0x4213, {0x9c, 0xa6, 0xcd, 0x4f, 0xdb, 0x92, 0x79, 0x72}};
const IID kIidKsControl = {0x28f54685, 0x06fd, 0x11d2, {0xb2, 0x7a, 0x00, 0xa0, 0xc9, 0x22, 0x31, 0x96}};
constexpr ULONG kKsPropertyDigitalWindow = 43;  // KSPROPERTY_CAMERACONTROL_EXTENDED_DIGITALWINDOW
constexpr ULONG kKsPropertyTypeGet = 0x1;
constexpr ULONG kKsPropertyTypeSet = 0x2;
constexpr ULONGLONG kDigitalWindowAutoFaceFraming = 0x1;
constexpr ULONG kFilterScope = 0xFFFFFFFF;

// KSPROPERTY: a union of the identifier with a LONGLONG, so 8 byte aligned
struct alignas(8) KsPropertyId {
  GUID set;
  ULONG id;
  ULONG flags;
};

// KSCAMERA_EXTENDEDPROP_HEADER
struct KsCameraExtendedHeader {
  ULONG version;
  ULONG pin_id;
  ULONG size;
  ULONG result;
  ULONGLONG flags;
  ULONGLONG capability;
};

// KSCAMERA_EXTENDEDPROP_DIGITALWINDOW_SETTING: the window in Q24 (1.0 is 0x01000000)
struct KsDigitalWindowSetting {
  LONG origin_x;
  LONG origin_y;
  LONG window_size;
  ULONG reserved;
};

// IKsControl (ksproxy.h)
struct IKsControlLocal : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE KsProperty(void* property, ULONG property_length, void* data, ULONG data_length,
                                               ULONG* returned) = 0;
  virtual HRESULT STDMETHODCALLTYPE KsMethod(void* method, ULONG method_length, void* data, ULONG data_length,
                                             ULONG* returned) = 0;
  virtual HRESULT STDMETHODCALLTYPE KsEvent(void* event, ULONG event_length, void* data, ULONG data_length,
                                            ULONG* returned) = 0;
};

template <typename T>
void SafeRelease(T** pointer) {
  if (*pointer != nullptr) {
    (*pointer)->Release();
    *pointer = nullptr;
  }
}

// The functions of Media Foundation, loaded once
struct MediaFoundation {
  using StartupFunction = HRESULT(STDAPICALLTYPE*)(ULONG, DWORD);
  using ShutdownFunction = HRESULT(STDAPICALLTYPE*)();
  using CreateAttributesFunction = HRESULT(STDAPICALLTYPE*)(IMFAttributes**, UINT32);
  using CreateMediaTypeFunction = HRESULT(STDAPICALLTYPE*)(IMFMediaType**);
  using EnumDeviceSourcesFunction = HRESULT(STDAPICALLTYPE*)(IMFAttributes*, IMFActivate***, UINT32*);
  using ReaderFromSourceFunction = HRESULT(STDAPICALLTYPE*)(IMFMediaSource*, IMFAttributes*, IMFSourceReader**);
  using ReaderFromUrlFunction = HRESULT(STDAPICALLTYPE*)(LPCWSTR, IMFAttributes*, IMFSourceReader**);

  StartupFunction startup = nullptr;
  ShutdownFunction shutdown = nullptr;
  CreateAttributesFunction create_attributes = nullptr;
  CreateMediaTypeFunction create_media_type = nullptr;
  EnumDeviceSourcesFunction enum_device_sources = nullptr;
  ReaderFromSourceFunction reader_from_source = nullptr;
  ReaderFromUrlFunction reader_from_url = nullptr;
};

// A function of a DLL loaded at run time
template <typename T>
T Lookup(HMODULE module, const char* name) {
  return reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(module, name)));
}

const MediaFoundation* LoadMediaFoundation() {
  static MediaFoundation api;
  static bool loaded = [] {
    HMODULE mfplat = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE mfreadwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE mf = LoadLibraryExW(L"mf.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (mfplat == nullptr || mfreadwrite == nullptr || mf == nullptr) {
      return false;
    }
    api.startup = Lookup<MediaFoundation::StartupFunction>(mfplat, "MFStartup");
    api.shutdown = Lookup<MediaFoundation::ShutdownFunction>(mfplat, "MFShutdown");
    api.create_attributes = Lookup<MediaFoundation::CreateAttributesFunction>(mfplat, "MFCreateAttributes");
    api.create_media_type = Lookup<MediaFoundation::CreateMediaTypeFunction>(mfplat, "MFCreateMediaType");
    api.enum_device_sources = Lookup<MediaFoundation::EnumDeviceSourcesFunction>(mf, "MFEnumDeviceSources");
    api.reader_from_source =
        Lookup<MediaFoundation::ReaderFromSourceFunction>(mfreadwrite, "MFCreateSourceReaderFromMediaSource");
    api.reader_from_url = Lookup<MediaFoundation::ReaderFromUrlFunction>(mfreadwrite, "MFCreateSourceReaderFromURL");
    return api.startup != nullptr && api.shutdown != nullptr && api.create_attributes != nullptr &&
           api.create_media_type != nullptr && api.enum_device_sources != nullptr &&
           api.reader_from_source != nullptr && api.reader_from_url != nullptr;
  }();
  return loaded ? &api : nullptr;
}

// COM in the multithreaded apartment for the life of the object, undone only when this object did it (a thread already
// in a single threaded apartment keeps it)
class ComScope {
 public:
  ComScope() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComScope() {
    if (SUCCEEDED(result_)) {
      CoUninitialize();
    }
  }
  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  HRESULT result_;
};

// MFStartup and MFShutdown around the life of the object
class MfScope {
 public:
  explicit MfScope(const MediaFoundation* mf) : mf_(mf), result_(mf->startup(MF_VERSION, MFSTARTUP_LITE)) {}
  ~MfScope() {
    if (SUCCEEDED(result_)) {
      mf_->shutdown();
    }
  }
  MfScope(const MfScope&) = delete;
  MfScope& operator=(const MfScope&) = delete;
  HRESULT result() const { return result_; }

 private:
  const MediaFoundation* mf_;
  HRESULT result_;
};

int32_t StatusOf(HRESULT hr, bool streaming) {
  if (hr == kAccessDenied) {
    return HT_E_ACCESS_DENIED;
  }
  if (hr == kSharingViolation || hr == kDeviceInUse || hr == kRecordingDevicePreempted ||
      hr == kHwMftFailedStartStreaming) {
    return streaming ? HT_E_DEVICE_LOST : HT_E_CAMERA_BUSY;
  }
  if (hr == kRecordingDeviceInvalidated || hr == kDeviceRemoved || hr == kDeviceNotConnected || hr == kGenFailure) {
    return HT_E_DEVICE_LOST;
  }
  if (hr == kFileNotFound || hr == kPathNotFound) {
    return HT_E_NO_CAMERA;
  }
  if (hr == kInvalidMediaType || hr == kTopoCodecNotFound || hr == kUnsupportedByteStream ||
      hr == kUnsupportedScheme || hr == kInvalidStreamNumber || hr == kNoMoreTypes) {
    return HT_E_FORMAT;
  }
  return HT_E_FAILED;
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &wide[0], length);
  return wide;
}

std::string Utf8(const wchar_t* text) {
  if (text == nullptr || text[0] == L'\0') {
    return std::string();
  }
  const int length = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) {
    return std::string();
  }
  std::string narrow(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, &narrow[0], length, nullptr, nullptr);
  narrow.resize(static_cast<size_t>(length) - 1);
  return narrow;
}

void AppendJsonString(std::string* json, const std::string& text) {
  static const char kHex[] = "0123456789abcdef";
  json->push_back('"');
  for (const char c : text) {
    const unsigned char u = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
      json->push_back('\\');
      json->push_back(c);
    } else if (u < 0x20) {
      json->append("\\u00");
      json->push_back(kHex[u >> 4]);
      json->push_back(kHex[u & 0xF]);
    } else {
      json->push_back(c);
    }
  }
  json->push_back('"');
}

// The video capture devices, in the colour camera category first and, if that lists none (an older driver model),
// without a category
HRESULT EnumerateCameras(const MediaFoundation* mf, IMFActivate*** devices, UINT32* count) {
  *devices = nullptr;
  *count = 0;
  for (int pass = 0; pass < 2; pass++) {
    IMFAttributes* attributes = nullptr;
    HRESULT hr = mf->create_attributes(&attributes, 2);
    if (FAILED(hr)) {
      return hr;
    }
    hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (SUCCEEDED(hr) && pass == 0) {
      hr = attributes->SetGUID(kVidcapCategory, kKsCategoryVideoCamera);
    }
    if (SUCCEEDED(hr)) {
      hr = mf->enum_device_sources(attributes, devices, count);
    }
    attributes->Release();
    if (FAILED(hr) && pass == 0) {
      continue;
    }
    if (FAILED(hr) || *count > 0) {
      return hr;
    }
    CoTaskMemFree(*devices);
    *devices = nullptr;
  }
  return S_OK;
}

void FreeDevices(IMFActivate** devices, UINT32 count) {
  if (devices == nullptr) {
    return;
  }
  for (UINT32 i = 0; i < count; i++) {
    SafeRelease(&devices[i]);
  }
  CoTaskMemFree(devices);
}

std::string DeviceString(IMFActivate* device, const GUID& key) {
  WCHAR* value = nullptr;
  UINT32 length = 0;
  if (FAILED(device->GetAllocatedString(key, &value, &length))) {
    return std::string();
  }
  std::string text = Utf8(value);
  CoTaskMemFree(value);
  return text;
}

// The subtypes whose luma the tracker reads straight from the buffer: offset of the first luma byte and the step
// between two of them
bool LumaLayout(const GUID& subtype, int32_t* offset, int32_t* step) {
  if (subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_I420 || subtype == MFVideoFormat_IYUV ||
      subtype == MFVideoFormat_YV12 || subtype == MFVideoFormat_L8) {
    *offset = 0;
    *step = 1;
    return true;
  }
  if (subtype == MFVideoFormat_YUY2) {
    *offset = 0;
    *step = 2;
    return true;
  }
  if (subtype == MFVideoFormat_UYVY) {
    *offset = 1;
    *step = 2;
    return true;
  }
  return false;
}

// The stream as the reader delivers it
struct Format {
  GUID subtype = {};
  int32_t width = 0;
  int32_t height = 0;
  int32_t default_stride = 0;
  int32_t offset = 0;
  int32_t step = 1;
  int32_t crop_x = 0;
  int32_t crop_y = 0;
  int32_t crop_width = 0;
  int32_t crop_height = 0;
};

HRESULT ReadFormat(IMFSourceReader* reader, Format* format) {
  IMFMediaType* type = nullptr;
  HRESULT hr = reader->GetCurrentMediaType(kFirstVideoStream, &type);
  if (FAILED(hr)) {
    return hr;
  }
  Format f;
  UINT32 width = 0, height = 0;
  hr = type->GetGUID(MF_MT_SUBTYPE, &f.subtype);
  if (SUCCEEDED(hr)) {
    hr = MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width, &height);
  }
  if (SUCCEEDED(hr) && !LumaLayout(f.subtype, &f.offset, &f.step)) {
    hr = kInvalidMediaType;
  }
  if (SUCCEEDED(hr)) {
    f.width = static_cast<int32_t>(width);
    f.height = static_cast<int32_t>(height);
    UINT32 stride = 0;
    if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))) {
      f.default_stride = static_cast<int32_t>(stride);
    } else {
      f.default_stride = f.width * f.step;
    }
    // A decoder may give a frame taller than the picture (1088 rows for 1080): the aperture says which part shows
    MFVideoArea area;
    UINT32 size = 0;
    if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area),
                                static_cast<UINT32>(sizeof(area)), &size)) &&
        size == static_cast<UINT32>(sizeof(area)) && area.Area.cx > 0 && area.Area.cy > 0 && area.OffsetX.value >= 0 &&
        area.OffsetY.value >= 0 && area.OffsetX.value + area.Area.cx <= f.width &&
        area.OffsetY.value + area.Area.cy <= f.height) {
      f.crop_x = area.OffsetX.value;
      f.crop_y = area.OffsetY.value;
      f.crop_width = area.Area.cx;
      f.crop_height = area.Area.cy;
    } else {
      f.crop_width = f.width;
      f.crop_height = f.height;
    }
    if (f.crop_width < 16 || f.crop_height < 16) {
      hr = kInvalidMediaType;
    }
  }
  type->Release();
  if (SUCCEEDED(hr)) {
    *format = f;
  }
  return hr;
}

// Asks the reader for a subtype whose luma the tracker reads, keeping the native one when it is such a subtype and
// asking for NV12 otherwise (the reader adds the MJPEG or H.264 decoder and the colour converter)
HRESULT SetOutputType(const MediaFoundation* mf, IMFSourceReader* reader) {
  IMFMediaType* native = nullptr;
  HRESULT hr = reader->GetCurrentMediaType(kFirstVideoStream, &native);
  if (FAILED(hr)) {
    hr = reader->GetNativeMediaType(kFirstVideoStream, 0, &native);
  }
  if (FAILED(hr)) {
    return hr;
  }
  GUID subtype = {};
  native->GetGUID(MF_MT_SUBTYPE, &subtype);
  native->Release();
  int32_t offset = 0, step = 0;
  if (LumaLayout(subtype, &offset, &step)) {
    return S_OK;
  }
  IMFMediaType* wanted = nullptr;
  hr = mf->create_media_type(&wanted);
  if (FAILED(hr)) {
    return hr;
  }
  hr = wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) {
    hr = wanted->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  }
  if (SUCCEEDED(hr)) {
    hr = reader->SetCurrentMediaType(kFirstVideoStream, nullptr, wanted);
  }
  wanted->Release();
  return hr;
}

// Picks the native camera format closest to the size and rate asked for: the frame area nearest (a larger frame
// preferred to a smaller one), then the rate nearest at or above the one asked for, then a format the tracker reads
// without a decoder
HRESULT ChooseCameraFormat(IMFSourceReader* reader, const HtOptions& options) {
  IMFMediaType* best = nullptr;
  double best_score = 0;
  for (DWORD index = 0;; index++) {
    IMFMediaType* type = nullptr;
    const HRESULT hr = reader->GetNativeMediaType(kFirstVideoStream, index, &type);
    if (hr == kNoMoreTypes || FAILED(hr)) {
      break;
    }
    UINT32 width = 0, height = 0, numerator = 0, denominator = 0;
    GUID subtype = {};
    if (FAILED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width, &height)) || width == 0 || height == 0) {
      type->Release();
      continue;
    }
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    double fps = 30;
    if (SUCCEEDED(MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &numerator, &denominator)) && denominator != 0) {
      fps = static_cast<double>(numerator) / denominator;
    }
    const double area = static_cast<double>(width) * height;
    const double wanted_area = static_cast<double>(options.width) * options.height;
    double score = area >= wanted_area ? area / wanted_area - 1 : (wanted_area / area - 1) * 2;
    score += fps >= options.fps ? (fps - options.fps) / options.fps * 0.25 : (options.fps - fps) / options.fps * 2;
    int32_t offset = 0, step = 0;
    if (!LumaLayout(subtype, &offset, &step)) {
      score += 0.05;
    }
    if (best == nullptr || score < best_score) {
      SafeRelease(&best);
      best = type;
      best_score = score;
    } else {
      type->Release();
    }
  }
  if (best == nullptr) {
    return kInvalidMediaType;
  }
  const HRESULT hr = reader->SetCurrentMediaType(kFirstVideoStream, nullptr, best);
  best->Release();
  return hr;
}

// The reader's attributes: the advanced video processing allows the colour conversion to NV12 (from YUY2 or the MJPEG
// decoder's output)
HRESULT ReaderAttributes(const MediaFoundation* mf, IMFAttributes** attributes) {
  HRESULT hr = mf->create_attributes(attributes, 2);
  if (SUCCEEDED(hr)) {
    hr = (*attributes)->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  }
  return hr;
}

// Runs the analysis on one sample's buffer
HRESULT AnalyseSample(IMFSample* sample, const Format& format, Core* core, int64_t time_us, HtSample* out) {
  IMFMediaBuffer* buffer = nullptr;
  DWORD buffers = 0;
  HRESULT hr = sample->GetBufferCount(&buffers);
  if (SUCCEEDED(hr)) {
    hr = buffers == 1 ? sample->GetBufferByIndex(0, &buffer) : sample->ConvertToContiguousBuffer(&buffer);
  }
  if (FAILED(hr)) {
    return hr;
  }
  IMF2DBuffer* buffer2d = nullptr;
  BYTE* data = nullptr;
  LONG pitch = 0;
  DWORD length = 0;
  bool locked2d = false;
  if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d))) && SUCCEEDED(buffer2d->Lock2D(&data, &pitch))) {
    locked2d = true;
  } else {
    SafeRelease(&buffer2d);
    DWORD max_length = 0;
    hr = buffer->Lock(&data, &max_length, &length);
    pitch = format.default_stride;
  }
  if (SUCCEEDED(hr)) {
    const ptrdiff_t stride = pitch;
    const ptrdiff_t abs_stride = stride < 0 ? -stride : stride;
    const bool fits = locked2d || static_cast<ptrdiff_t>(length) >=
                                      abs_stride * (format.crop_y + format.crop_height);
    if (fits && abs_stride >= static_cast<ptrdiff_t>(format.width) * format.step) {
      LumaPlane plane;
      plane.data = data + static_cast<ptrdiff_t>(format.crop_y) * stride +
                   static_cast<ptrdiff_t>(format.crop_x) * format.step + format.offset;
      plane.width = format.crop_width;
      plane.height = format.crop_height;
      plane.stride = stride;
      plane.pixel_step = format.step;
      core->Analyse(plane, time_us, out);
    } else {
      hr = kInvalidMediaType;
    }
    if (locked2d) {
      buffer2d->Unlock2D();
    } else {
      buffer->Unlock();
    }
  }
  SafeRelease(&buffer2d);
  buffer->Release();
  return hr;
}

// Windows Studio Effects automatic framing keeps the face in the middle of the picture, which would flatten the
// parallax: read KSPROPERTY_CAMERACONTROL_EXTENDED_DIGITALWINDOW and, when it is on, ask for the full view for this
// stream. The control only answers while the camera streams.
int32_t TurnOffAutoFraming(IMFMediaSource* source, bool* turned_off) {
  *turned_off = false;
  IKsControlLocal* control = nullptr;
  if (FAILED(source->QueryInterface(kIidKsControl, reinterpret_cast<void**>(&control)))) {
    return HT_FRAMING_ABSENT;
  }
  struct alignas(8) Payload {
    KsCameraExtendedHeader header;
    BYTE setting[64];
  } payload;
  ZeroMemory(&payload, sizeof(payload));
  KsPropertyId property = {kKsPropertySetExtendedCameraControl, kKsPropertyDigitalWindow, kKsPropertyTypeGet};
  ULONG returned = 0;
  HRESULT hr = control->KsProperty(&property, static_cast<ULONG>(sizeof(property)), &payload,
                                   static_cast<ULONG>(sizeof(payload)), &returned);
  int32_t framing = HT_FRAMING_ABSENT;
  if (SUCCEEDED(hr) && returned >= sizeof(KsCameraExtendedHeader) &&
      (payload.header.capability & kDigitalWindowAutoFaceFraming) != 0) {
    if ((payload.header.flags & kDigitalWindowAutoFaceFraming) == 0) {
      framing = HT_FRAMING_OFF;
    } else {
      payload.header.version = 1;
      payload.header.pin_id = kFilterScope;
      payload.header.size = static_cast<ULONG>(sizeof(KsCameraExtendedHeader) + sizeof(KsDigitalWindowSetting));
      payload.header.result = 0;
      payload.header.flags = 0;  // KSCAMERA_EXTENDEDPROP_DIGITALWINDOW_MANUAL
      KsDigitalWindowSetting setting = {0, 0, 0x01000000, 0};
      memcpy(payload.setting, &setting, sizeof(setting));
      property.flags = kKsPropertyTypeSet;
      hr = control->KsProperty(&property, static_cast<ULONG>(sizeof(property)), &payload, payload.header.size,
                               &returned);
      framing = SUCCEEDED(hr) ? HT_FRAMING_TURNED_OFF : HT_FRAMING_STUCK_ON;
      *turned_off = SUCCEEDED(hr);
    }
  }
  control->Release();
  return framing;
}

// Gives the camera its automatic framing back before the stream stops, when the tracker turned it off
void RestoreAutoFraming(IMFMediaSource* source) {
  IKsControlLocal* control = nullptr;
  if (FAILED(source->QueryInterface(kIidKsControl, reinterpret_cast<void**>(&control)))) {
    return;
  }
  struct alignas(8) Payload {
    KsCameraExtendedHeader header;
    KsDigitalWindowSetting setting;
  } payload;
  ZeroMemory(&payload, sizeof(payload));
  payload.header.version = 1;
  payload.header.pin_id = kFilterScope;
  payload.header.size = static_cast<ULONG>(sizeof(payload));
  payload.header.flags = kDigitalWindowAutoFaceFraming;
  payload.setting.window_size = 0x01000000;
  KsPropertyId property = {kKsPropertySetExtendedCameraControl, kKsPropertyDigitalWindow, kKsPropertyTypeSet};
  ULONG returned = 0;
  control->KsProperty(&property, static_cast<ULONG>(sizeof(property)), &payload, static_cast<ULONG>(sizeof(payload)),
                      &returned);
  control->Release();
}

uint32_t FourCc(const GUID& subtype) {
  // The video subtypes are FOURCC GUIDs: the code is Data1
  return static_cast<uint32_t>(subtype.Data1);
}

// What the camera thread and ht_close share
struct CameraState {
  std::wstring id;
  HtOptions options{};
  std::unique_ptr<Core> core;
  std::shared_ptr<Shared> shared;
  std::atomic<bool> stop{false};
  // The source, so that a stop can shut it down when a read hangs
  std::mutex source_mutex;
  IMFMediaSource* source = nullptr;
  std::mutex done_mutex;
  std::condition_variable done_signal;
  bool done = false;
};

void FailCamera(CameraState* state, int32_t status, HRESULT hr, int64_t sequence) {
  HtSample sample;
  ZeroMemory(&sample, sizeof(sample));
  {
    std::lock_guard<std::mutex> lock(state->shared->mutex);
    state->shared->info.hresult = static_cast<int32_t>(hr);
    if (state->shared->has_latest) {
      sample = state->shared->latest;
    }
  }
  sample.sequence = sequence + 1;
  sample.status = status;
  sample.time_us = NowUs();
  state->shared->Publish(sample);
}

void RunCamera(std::shared_ptr<CameraState> state) {
  ComScope com;
  const MediaFoundation* mf = LoadMediaFoundation();
  if (mf == nullptr) {
    FailCamera(state.get(), HT_E_NO_MEDIA_FOUNDATION, S_OK, 0);
    std::lock_guard<std::mutex> lock(state->done_mutex);
    state->done = true;
    state->done_signal.notify_all();
    return;
  }
  int64_t sequence = 0;
  HRESULT hr = S_OK;
  int32_t status = HT_OK;
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  IMFMediaSource* source = nullptr;
  IMFSourceReader* reader = nullptr;
  IMFAttributes* attributes = nullptr;
  bool framing_checked = false;
  bool framing_turned_off = false;
  {
    MfScope started(mf);
    hr = started.result();
    if (SUCCEEDED(hr)) {
      hr = EnumerateCameras(mf, &devices, &count);
    }
    if (SUCCEEDED(hr)) {
      IMFActivate* chosen = nullptr;
      for (UINT32 i = 0; i < count && chosen == nullptr; i++) {
        WCHAR* link = nullptr;
        UINT32 length = 0;
        if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link,
                                                       &length))) {
          if (_wcsicmp(link, state->id.c_str()) == 0) {
            chosen = devices[i];
          }
          CoTaskMemFree(link);
        }
      }
      if (chosen == nullptr) {
        status = HT_E_NO_CAMERA;
      } else {
        hr = chosen->ActivateObject(IID_PPV_ARGS(&source));
      }
    }
    FreeDevices(devices, count);
    devices = nullptr;
    if (SUCCEEDED(hr) && status == HT_OK) {
      std::lock_guard<std::mutex> lock(state->source_mutex);
      state->source = source;
      source->AddRef();
    }
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = ReaderAttributes(mf, &attributes);
    }
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = mf->reader_from_source(source, attributes, &reader);
    }
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = reader->SetStreamSelection(kAllStreams, FALSE);
      if (SUCCEEDED(hr)) {
        hr = reader->SetStreamSelection(kFirstVideoStream, TRUE);
      }
    }
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = ChooseCameraFormat(reader, state->options);
    }
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = SetOutputType(mf, reader);
    }
    Format format;
    if (SUCCEEDED(hr) && status == HT_OK) {
      hr = ReadFormat(reader, &format);
    }
    if (FAILED(hr) && status == HT_OK) {
      status = StatusOf(hr, false);
    }
    bool streaming = false;
    if (status == HT_OK) {
      IMFMediaType* native = nullptr;
      const DWORD current = static_cast<DWORD>(MF_SOURCE_READER_CURRENT_TYPE_INDEX);
      if (SUCCEEDED(reader->GetNativeMediaType(kFirstVideoStream, current, &native))) {
        GUID subtype = {};
        UINT32 numerator = 0, denominator = 0;
        native->GetGUID(MF_MT_SUBTYPE, &subtype);
        MFGetAttributeRatio(native, MF_MT_FRAME_RATE, &numerator, &denominator);
        std::lock_guard<std::mutex> lock(state->shared->mutex);
        state->shared->info.native_fourcc = FourCc(subtype);
        state->shared->info.fps_numerator = static_cast<int32_t>(numerator);
        state->shared->info.fps_denominator = static_cast<int32_t>(denominator);
        native->Release();
      }
      std::lock_guard<std::mutex> lock(state->shared->mutex);
      state->shared->info.width = format.crop_width;
      state->shared->info.height = format.crop_height;
    }
    while (status == HT_OK && !state->stop.load()) {
      DWORD stream = 0, flags = 0;
      LONGLONG timestamp = 0;
      IMFSample* sample = nullptr;
      hr = reader->ReadSample(kFirstVideoStream, 0, &stream, &flags, &timestamp, &sample);
      if (state->stop.load()) {
        SafeRelease(&sample);
        break;
      }
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) != 0) {
        status = StatusOf(FAILED(hr) ? hr : E_FAIL, streaming);
        SafeRelease(&sample);
        break;
      }
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        status = HT_E_DEVICE_LOST;
        hr = kRecordingDeviceInvalidated;
        SafeRelease(&sample);
        break;
      }
      if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        hr = ReadFormat(reader, &format);
        if (FAILED(hr)) {
          status = StatusOf(hr, streaming);
          SafeRelease(&sample);
          break;
        }
      }
      if (sample == nullptr) {
        continue;
      }
      streaming = true;
      const int64_t now = NowUs();
      if (state->core->CountFrame()) {
        HtSample out;
        hr = AnalyseSample(sample, format, state->core.get(), now, &out);
        if (SUCCEEDED(hr)) {
          sequence = out.sequence;
          state->shared->Publish(out);
        }
      }
      sample->Release();
      if (!framing_checked) {
        framing_checked = true;
        const int32_t framing = TurnOffAutoFraming(source, &framing_turned_off);
        std::lock_guard<std::mutex> lock(state->shared->mutex);
        state->shared->info.framing = framing;
      }
    }
    if (framing_turned_off && source != nullptr && status == HT_OK) {
      RestoreAutoFraming(source);
    }
    SafeRelease(&reader);
    SafeRelease(&attributes);
    {
      std::lock_guard<std::mutex> lock(state->source_mutex);
      SafeRelease(&state->source);
    }
    if (source != nullptr) {
      source->Shutdown();
      SafeRelease(&source);
    }
  }
  if (status != HT_OK && !state->stop.load()) {
    FailCamera(state.get(), status, hr, sequence);
  }
  {
    std::lock_guard<std::mutex> lock(state->done_mutex);
    state->done = true;
  }
  state->done_signal.notify_all();
}

class CameraSource : public Source {
 public:
  explicit CameraSource(std::shared_ptr<CameraState> state) : state_(std::move(state)) {}
  ~CameraSource() override { Stop(); }

  int32_t Next(Tracker* tracker, HtSample* sample) override {
    (void)tracker;
    (void)sample;
    return HT_E_ARGUMENT;
  }

  void Stop() override {
    if (!thread_.joinable()) {
      return;
    }
    state_->stop.store(true);
    std::unique_lock<std::mutex> lock(state_->done_mutex);
    // A frame comes every 33 ms or so; a camera that sends none for a second gets its source shut down, which ends the
    // read in progress
    if (!state_->done_signal.wait_for(lock, std::chrono::seconds(1), [this] { return state_->done; })) {
      {
        std::lock_guard<std::mutex> source_lock(state_->source_mutex);
        if (state_->source != nullptr) {
          state_->source->Shutdown();
        }
      }
      state_->done_signal.wait_for(lock, std::chrono::seconds(2), [this] { return state_->done; });
    }
    const bool done = state_->done;
    lock.unlock();
    if (done) {
      thread_.join();
    } else {
      // A driver that hangs: the thread keeps its own reference to the state and ends whenever the driver lets it
      thread_.detach();
    }
  }

  void Start() { thread_ = std::thread(RunCamera, state_); }

 private:
  std::shared_ptr<CameraState> state_;
  std::thread thread_;
};

class FileSource : public Source {
 public:
  FileSource(const MediaFoundation* mf, IMFSourceReader* reader, const Format& format)
      : mf_(mf), reader_(reader), format_(format) {}
  ~FileSource() override {
    ComScope com;
    SafeRelease(&reader_);
    // The start of OpenFile
    mf_->shutdown();
  }

  int32_t Next(Tracker* tracker, HtSample* out) override {
    ComScope com;
    if (ended_) {
      return 0;
    }
    for (;;) {
      DWORD stream = 0, flags = 0;
      LONGLONG timestamp = 0;
      IMFSample* sample = nullptr;
      HRESULT hr = reader_->ReadSample(kFirstVideoStream, 0, &stream, &flags, &timestamp, &sample);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) != 0) {
        SafeRelease(&sample);
        Record(tracker, FAILED(hr) ? hr : E_FAIL);
        return StatusOf(FAILED(hr) ? hr : E_FAIL, false);
      }
      if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0) {
        hr = ReadFormat(reader_, &format_);
        if (FAILED(hr)) {
          SafeRelease(&sample);
          Record(tracker, hr);
          return StatusOf(hr, false);
        }
      }
      if (sample == nullptr) {
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
          ended_ = true;
          return 0;
        }
        continue;
      }
      if (!tracker->core->CountFrame()) {
        sample->Release();
        continue;
      }
      // 100 ns units
      hr = AnalyseSample(sample, format_, tracker->core.get(), timestamp / 10, out);
      sample->Release();
      if (FAILED(hr)) {
        Record(tracker, hr);
        return StatusOf(hr, false);
      }
      std::lock_guard<std::mutex> lock(tracker->shared->mutex);
      tracker->shared->latest = *out;
      tracker->shared->has_latest = true;
      return 1;
    }
  }

  void Stop() override {}

 private:
  static void Record(Tracker* tracker, HRESULT hr) {
    std::lock_guard<std::mutex> lock(tracker->shared->mutex);
    tracker->shared->info.hresult = static_cast<int32_t>(hr);
  }

  const MediaFoundation* mf_;
  IMFSourceReader* reader_;
  Format format_;
  bool ended_ = false;
};

}  // namespace

int32_t ListCameras(std::string* json) {
  const MediaFoundation* mf = LoadMediaFoundation();
  if (mf == nullptr) {
    return HT_E_NO_MEDIA_FOUNDATION;
  }
  ComScope com;
  MfScope started(mf);
  if (FAILED(started.result())) {
    return StatusOf(started.result(), false);
  }
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  const HRESULT hr = EnumerateCameras(mf, &devices, &count);
  if (FAILED(hr)) {
    return StatusOf(hr, false);
  }
  json->assign("[");
  for (UINT32 i = 0; i < count; i++) {
    if (i > 0) {
      json->push_back(',');
    }
    json->append("{\"id\":");
    AppendJsonString(json, DeviceString(devices[i], MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK));
    json->append(",\"name\":");
    AppendJsonString(json, DeviceString(devices[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME));
    json->push_back('}');
  }
  json->push_back(']');
  FreeDevices(devices, count);
  return HT_OK;
}

int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source) {
  if (LoadMediaFoundation() == nullptr) {
    return HT_E_NO_MEDIA_FOUNDATION;
  }
  auto state = std::make_shared<CameraState>();
  state->id = Wide(id);
  if (state->id.empty()) {
    return HT_E_ARGUMENT;
  }
  state->options = tracker->options;
  state->core = std::move(tracker->core);
  state->shared = tracker->shared;
  auto camera = std::make_unique<CameraSource>(state);
  camera->Start();
  *source = std::move(camera);
  return HT_OK;
}

int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source) {
  const MediaFoundation* mf = LoadMediaFoundation();
  if (mf == nullptr) {
    return HT_E_NO_MEDIA_FOUNDATION;
  }
  const std::wstring wide = Wide(path);
  if (wide.empty()) {
    return HT_E_ARGUMENT;
  }
  ComScope com;
  // The file source keeps Media Foundation started until it closes: MFStartup counts its callers
  HRESULT hr = mf->startup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    return StatusOf(hr, false);
  }
  IMFAttributes* attributes = nullptr;
  IMFSourceReader* reader = nullptr;
  hr = ReaderAttributes(mf, &attributes);
  if (SUCCEEDED(hr)) {
    hr = mf->reader_from_url(wide.c_str(), attributes, &reader);
  }
  SafeRelease(&attributes);
  if (SUCCEEDED(hr)) {
    hr = reader->SetStreamSelection(kAllStreams, FALSE);
  }
  if (SUCCEEDED(hr)) {
    hr = reader->SetStreamSelection(kFirstVideoStream, TRUE);
  }
  if (SUCCEEDED(hr)) {
    hr = SetOutputType(mf, reader);
  }
  Format format;
  if (SUCCEEDED(hr)) {
    hr = ReadFormat(reader, &format);
  }
  if (FAILED(hr)) {
    SafeRelease(&reader);
    mf->shutdown();
    std::lock_guard<std::mutex> lock(tracker->shared->mutex);
    tracker->shared->info.hresult = static_cast<int32_t>(hr);
    return hr == kFileNotFound || hr == kPathNotFound ? HT_E_ARGUMENT : StatusOf(hr, false);
  }
  {
    IMFMediaType* native = nullptr;
    if (SUCCEEDED(reader->GetNativeMediaType(kFirstVideoStream, 0, &native))) {
      GUID subtype = {};
      native->GetGUID(MF_MT_SUBTYPE, &subtype);
      std::lock_guard<std::mutex> lock(tracker->shared->mutex);
      tracker->shared->info.native_fourcc = FourCc(subtype);
      native->Release();
    }
    std::lock_guard<std::mutex> lock(tracker->shared->mutex);
    tracker->shared->info.width = format.crop_width;
    tracker->shared->info.height = format.crop_height;
  }
  // Media Foundation stays started for the file until FileSource's destructor
  *source = std::make_unique<FileSource>(mf, reader, format);
  return HT_OK;
}

}  // namespace ht
