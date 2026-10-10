// The decoder probe of Immuch360 Desktop (design 2.7): what the hardware video decoder of a GPU takes, read from
// Direct3D 11 (its decoder profiles, the output formats of each, and the frame sizes each accepts), with the frame
// rate Direct3D 12 tells where the driver answers it. One C function returns it all as JSON; Dart calls it through
// dart:ffi in a background isolate (lib/src/d3d11_decoders.dart), so nothing here registers with Flutter or keeps
// state between calls: each call makes its own devices and releases them before it returns.
//
// The GPU in use is the default adapter, the one media_kit_video creates its device on (angle_surface_manager.cc,
// D3D11CreateDevice without an adapter): Windows puts the GPU of the per app graphics preference first, so the
// decoders read here are those mpv decodes with.
//
// A size is checked the way FFmpeg's d3d11va asks for a decoder (dxva2.c, dxva_get_decoder_configuration): a decoder
// configuration with a raw bitstream must exist for that size and output format. Chromium checks sizes the same way
// (media/gpu/windows/supported_profile_helpers.cc), since creating a decoder for each size would cost far more.

#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3d12video.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

struct NamedFormat {
  DXGI_FORMAT format;
  const char* name;
};

// The output formats a decoder profile may write, in the order the size checks prefer: 8 bit 4:2:0 first, as most
// videos are, then 10 and 16 bit 4:2:0, then 4:2:2 and 4:4:4
constexpr NamedFormat kFormats[] = {
    {DXGI_FORMAT_NV12, "NV12"}, {DXGI_FORMAT_P010, "P010"}, {DXGI_FORMAT_P016, "P016"},
    {DXGI_FORMAT_YUY2, "YUY2"}, {DXGI_FORMAT_Y210, "Y210"}, {DXGI_FORMAT_Y216, "Y216"},
    {DXGI_FORMAT_AYUV, "AYUV"}, {DXGI_FORMAT_Y410, "Y410"}, {DXGI_FORMAT_Y416, "Y416"},
};

// A frame rate no decoder reaches at any size: a driver that accepts it does not check rates, and its answers to
// the real ones say nothing
constexpr UINT kUntoldRate = 100000;

// The rates asked at the largest size a profile takes, the highest first
constexpr UINT kRates[] = {480, 240, 120, 60, 50, 30, 25, 24};

std::string GuidText(const GUID& guid) {
  char text[40];
  std::snprintf(text, sizeof(text), "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                static_cast<unsigned long>(guid.Data1), static_cast<unsigned int>(guid.Data2),
                static_cast<unsigned int>(guid.Data3), static_cast<unsigned int>(guid.Data4[0]),
                static_cast<unsigned int>(guid.Data4[1]), static_cast<unsigned int>(guid.Data4[2]),
                static_cast<unsigned int>(guid.Data4[3]), static_cast<unsigned int>(guid.Data4[4]),
                static_cast<unsigned int>(guid.Data4[5]), static_cast<unsigned int>(guid.Data4[6]),
                static_cast<unsigned int>(guid.Data4[7]));
  return text;
}

// [text] as a JSON string, quotes included
std::string JsonString(const std::string& text) {
  std::string out = "\"";
  for (const char c : text) {
    const auto byte = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (byte < 0x20) {
      char escaped[8];
      std::snprintf(escaped, sizeof(escaped), "\\u%04x", static_cast<unsigned int>(byte));
      out += escaped;
    } else {
      out += c;
    }
  }
  out += '"';
  return out;
}

std::string Utf8(const wchar_t* text) {
  const int length = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) {
    return std::string();
  }
  std::string out(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), length, nullptr, nullptr);
  out.resize(static_cast<size_t>(length - 1));
  return out;
}

// The user mode driver version of [adapter] ("32.0.16.1656"), empty when Windows does not tell it
std::string DriverVersion(IDXGIAdapter* adapter) {
  LARGE_INTEGER version = {};
  if (FAILED(adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice), &version))) {
    return std::string();
  }
  char text[32];
  std::snprintf(text, sizeof(text), "%u.%u.%u.%u", static_cast<unsigned int>(HIWORD(version.HighPart)),
                static_cast<unsigned int>(LOWORD(version.HighPart)),
                static_cast<unsigned int>(HIWORD(version.LowPart)),
                static_cast<unsigned int>(LOWORD(version.LowPart)));
  return text;
}

bool SizeAccepted(ID3D11VideoDevice* video, const GUID& profile, DXGI_FORMAT format, UINT width, UINT height) {
  D3D11_VIDEO_DECODER_DESC desc = {};
  desc.Guid = profile;
  desc.SampleWidth = width;
  desc.SampleHeight = height;
  desc.OutputFormat = format;
  UINT count = 0;
  if (FAILED(video->GetVideoDecoderConfigCount(&desc, &count)) || count == 0) {
    return false;
  }
  for (UINT i = 0; i < count; i++) {
    D3D11_VIDEO_DECODER_CONFIG config = {};
    if (FAILED(video->GetVideoDecoderConfig(&desc, i, &config))) {
      return false;
    }
    // 1: the raw bitstream, 2: the raw bitstream with short slice headers (H.264): what FFmpeg hands over
    if (config.ConfigBitstreamRaw == 1 || config.ConfigBitstreamRaw == 2) {
      return true;
    }
  }
  return false;
}

bool RateAccepted(ID3D12VideoDevice* video, const GUID& profile, DXGI_FORMAT format, UINT width, UINT height,
                  UINT rate) {
  D3D12_FEATURE_DATA_VIDEO_DECODE_SUPPORT support = {};
  support.NodeIndex = 0;
  support.Configuration.DecodeProfile = profile;
  support.Configuration.BitstreamEncryption = D3D12_BITSTREAM_ENCRYPTION_TYPE_NONE;
  support.Configuration.InterlaceType = D3D12_VIDEO_FRAME_CODED_INTERLACE_TYPE_NONE;
  support.Width = width;
  support.Height = height;
  support.DecodeFormat = format;
  support.FrameRate.Numerator = rate;
  support.FrameRate.Denominator = 1;
  support.BitRate = 0;
  if (FAILED(video->CheckFeatureSupport(D3D12_FEATURE_VIDEO_DECODE_SUPPORT, &support, sizeof(support)))) {
    return false;
  }
  return (static_cast<UINT>(support.SupportFlags) & static_cast<UINT>(D3D12_VIDEO_DECODE_SUPPORT_FLAG_SUPPORTED)) !=
         0;
}

using D3D12CreateDeviceFunction = HRESULT(WINAPI*)(IUnknown*, D3D_FEATURE_LEVEL, REFIID, void**);

// The Direct3D 12 video device of [adapter], null when the system or the driver has none. d3d12.dll is loaded here
// rather than linked, so that the DLL of this plugin loads wherever Direct3D 11 does.
ComPtr<ID3D12VideoDevice> VideoDevice12(IDXGIAdapter* adapter, HMODULE* library) {
  *library = LoadLibraryExW(L"d3d12.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (*library == nullptr) {
    return nullptr;
  }
  const auto create = reinterpret_cast<D3D12CreateDeviceFunction>(
      reinterpret_cast<void*>(GetProcAddress(*library, "D3D12CreateDevice")));
  if (create == nullptr) {
    return nullptr;
  }
  ComPtr<ID3D12Device> device;
  if (FAILED(create(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) {
    return nullptr;
  }
  ComPtr<ID3D12VideoDevice> video;
  if (FAILED(device.As(&video))) {
    return nullptr;
  }
  return video;
}

// The adapter at [index] of DXGI's list with a Direct3D 11 device on it, or for a negative index the default
// adapter as media_kit_video gets it. Video support is asked: without it the device has no ID3D11VideoDevice.
HRESULT CreateDevice(int32_t index, ComPtr<IDXGIAdapter1>* adapter, ComPtr<ID3D11Device>* device) {
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  const UINT level_count = static_cast<UINT>(sizeof(levels) / sizeof(levels[0]));
  HRESULT result = S_OK;
  if (index < 0) {
    result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels,
                               level_count, D3D11_SDK_VERSION, device->GetAddressOf(), nullptr, nullptr);
    if (FAILED(result)) {
      return result;
    }
    ComPtr<IDXGIDevice> dxgi_device;
    result = device->As(&dxgi_device);
    if (FAILED(result)) {
      return result;
    }
    ComPtr<IDXGIAdapter> plain;
    result = dxgi_device->GetAdapter(&plain);
    if (FAILED(result)) {
      return result;
    }
    return plain.As(adapter);
  }
  ComPtr<IDXGIFactory1> factory;
  result = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(result)) {
    return result;
  }
  result = factory->EnumAdapters1(static_cast<UINT>(index), adapter->GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  return D3D11CreateDevice(adapter->Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, levels,
                           level_count, D3D11_SDK_VERSION, device->GetAddressOf(), nullptr, nullptr);
}

std::string AdapterJson(int32_t index, IDXGIAdapter1* adapter, ID3D11Device* device) {
  DXGI_ADAPTER_DESC1 desc = {};
  if (FAILED(adapter->GetDesc1(&desc))) {
    return "null";
  }
  // An integrated GPU shares the system memory (UMA); without the answer, a few hundred megabytes of its own say it
  bool integrated = desc.DedicatedVideoMemory < 512ull * 1024 * 1024;
  if (device != nullptr) {
    D3D11_FEATURE_DATA_D3D11_OPTIONS2 options = {};
    if (SUCCEEDED(device->CheckFeatureSupport(D3D11_FEATURE_D3D11_OPTIONS2, &options, sizeof(options)))) {
      integrated = options.UnifiedMemoryArchitecture != FALSE;
    }
  }
  char numbers[512];
  std::snprintf(numbers, sizeof(numbers),
                "\"index\":%d,\"vendorId\":%u,\"deviceId\":%u,\"subSysId\":%u,\"revision\":%u,"
                "\"dedicatedMB\":%llu,\"sharedMB\":%llu,\"integrated\":%s,\"software\":%s,\"luid\":\"%08lx:%08lx\"",
                static_cast<int>(index), static_cast<unsigned int>(desc.VendorId),
                static_cast<unsigned int>(desc.DeviceId), static_cast<unsigned int>(desc.SubSysId),
                static_cast<unsigned int>(desc.Revision),
                static_cast<unsigned long long>(desc.DedicatedVideoMemory / (1024 * 1024)),
                static_cast<unsigned long long>(desc.SharedSystemMemory / (1024 * 1024)),
                integrated ? "true" : "false", (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 ? "true" : "false",
                static_cast<unsigned long>(desc.AdapterLuid.HighPart),
                static_cast<unsigned long>(desc.AdapterLuid.LowPart));
  return std::string("{\"name\":") + JsonString(Utf8(desc.Description)) +
         ",\"driver\":" + JsonString(DriverVersion(adapter)) + "," + numbers + "}";
}

std::string Probe(int32_t index, const char* filter, const int32_t* sizes, int32_t size_count, bool rates) {
  ComPtr<IDXGIAdapter1> adapter;
  ComPtr<ID3D11Device> device;
  const HRESULT created = CreateDevice(index, &adapter, &device);
  std::string json = "{";
  if (adapter != nullptr) {
    json += "\"adapter\":" + AdapterJson(index, adapter.Get(), device.Get()) + ",";
  }
  ComPtr<ID3D11VideoDevice> video;
  if (FAILED(created) || FAILED(device.As(&video))) {
    char error[64];
    std::snprintf(error, sizeof(error), "no video device (0x%08lx)",
                  static_cast<unsigned long>(FAILED(created) ? created : E_NOINTERFACE));
    return json + "\"profiles\":[],\"error\":" + JsonString(error) + "}";
  }
  HMODULE d3d12_library = nullptr;
  ComPtr<ID3D12VideoDevice> video12;
  if (rates) {
    video12 = VideoDevice12(adapter.Get(), &d3d12_library);
  }
  json += std::string("\"d3d12\":") + (video12 != nullptr ? "true" : "false") + ",\"profiles\":[";
  const UINT count = video->GetVideoDecoderProfileCount();
  bool first = true;
  for (UINT i = 0; i < count; i++) {
    GUID profile = {};
    if (FAILED(video->GetVideoDecoderProfile(i, &profile))) {
      continue;
    }
    const std::string guid = GuidText(profile);
    json += first ? "{" : ",{";
    first = false;
    json += "\"guid\":\"" + guid + "\",\"formats\":[";
    const NamedFormat* test_format = nullptr;
    bool first_format = true;
    for (const auto& format : kFormats) {
      BOOL supported = FALSE;
      if (SUCCEEDED(video->CheckVideoDecoderFormat(&profile, format.format, &supported)) && supported) {
        json += std::string(first_format ? "" : ",") + "\"" + format.name + "\"";
        first_format = false;
        if (test_format == nullptr) {
          test_format = &format;
        }
      }
    }
    json += "]";
    // Only the profiles Dart asked about get their sizes checked: a driver lists dozens (JPEG, legacy MPEG
    // acceleration levels), and each check is a call into it
    const bool wanted = filter == nullptr || filter[0] == '\0' || std::strstr(filter, guid.c_str()) != nullptr;
    if (test_format == nullptr || !wanted) {
      json += "}";
      continue;
    }
    json += std::string(",\"sizeFormat\":\"") + test_format->name + "\",\"sizes\":[";
    UINT largest_width = 0;
    UINT largest_height = 0;
    for (int32_t s = 0; s + 1 < size_count * 2; s += 2) {
      const auto width = static_cast<UINT>(sizes[s]);
      const auto height = static_cast<UINT>(sizes[s + 1]);
      const bool accepted = SizeAccepted(video.Get(), profile, test_format->format, width, height);
      char entry[48];
      std::snprintf(entry, sizeof(entry), "%s[%u,%u,%d]", s == 0 ? "" : ",", width, height, accepted ? 1 : 0);
      json += entry;
      if (accepted && static_cast<unsigned long long>(width) * height >
                          static_cast<unsigned long long>(largest_width) * largest_height) {
        largest_width = width;
        largest_height = height;
      }
    }
    json += "]";
    if (video12 != nullptr && largest_width > 0) {
      int max_rate = 0;
      const bool untold = RateAccepted(video12.Get(), profile, test_format->format, largest_width, largest_height,
                                       kUntoldRate);
      if (!untold) {
        for (const UINT rate : kRates) {
          if (RateAccepted(video12.Get(), profile, test_format->format, largest_width, largest_height, rate)) {
            max_rate = static_cast<int>(rate);
            break;
          }
        }
      }
      char entry[96];
      std::snprintf(entry, sizeof(entry), ",\"rate\":{\"width\":%u,\"height\":%u,\"max\":%d,\"untold\":%s}",
                    largest_width, largest_height, max_rate, untold ? "true" : "false");
      json += entry;
    }
    json += "}";
  }
  json += "]}";
  video12.Reset();
  if (d3d12_library != nullptr) {
    FreeLibrary(d3d12_library);
  }
  return json;
}

}  // namespace

extern "C" {

// The adapters DXGI lists (GPUs, the software renderer, virtual display adapters), in its order: the first is the
// one the per app graphics preference picks
__declspec(dllexport) int32_t immuch_dv_adapter_count() {
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return 0;
  }
  int32_t count = 0;
  ComPtr<IDXGIAdapter1> adapter;
  while (factory->EnumAdapters1(static_cast<UINT>(count), adapter.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND) {
    count++;
  }
  return count;
}

// Writes the JSON description of the decoders of the adapter [adapter_index] (negative: the default adapter, the one
// the app's video renders on) into [out], [capacity] bytes with the closing zero. [profile_filter] holds the GUIDs
// (lower case, without braces) whose sizes are checked, all when empty; [sizes] holds [size_count] pairs of width
// and height; [check_rates] asks Direct3D 12 for the frame rate at the largest size each profile takes. Returns the
// length of the JSON: when it is [capacity] or more, nothing usable was written and the call is made again with a
// larger buffer.
__declspec(dllexport) int32_t immuch_dv_probe(int32_t adapter_index, const char* profile_filter, const int32_t* sizes,
                                              int32_t size_count, int32_t check_rates, char* out, int32_t capacity) {
  const std::string json =
      Probe(adapter_index, profile_filter, sizes, sizes == nullptr ? 0 : size_count, check_rates != 0);
  const auto length = static_cast<int32_t>(json.size());
  if (out != nullptr && capacity > length) {
    std::memcpy(out, json.c_str(), json.size() + 1);
  }
  return length;
}

}  // extern "C"
