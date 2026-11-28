#include "share_channel.h"

#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kShareChannel[] = "immuch360/share";

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                           static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), utf16.data(),
                        length);
  return utf16;
}

std::string Utf8FromUtf16(const std::wstring& utf16) {
  if (utf16.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, utf16.data(), static_cast<int>(utf16.size()), nullptr, 0,
                                           nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, utf16.data(), static_cast<int>(utf16.size()), utf8.data(), length, nullptr,
                        nullptr);
  return utf8;
}

std::string HexOf(HRESULT hr) {
  char buffer[16];
  std::snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(hr));
  return buffer;
}

// The paths of the "paths" argument, in UTF-16; false when it is missing or holds no text
bool PathsOf(const flutter::EncodableMap& arguments, std::vector<std::wstring>* paths) {
  const auto found = arguments.find(flutter::EncodableValue("paths"));
  if (found == arguments.end()) {
    return false;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&found->second);
  if (list == nullptr) {
    return false;
  }
  for (const auto& value : *list) {
    const auto* path = std::get_if<std::string>(&value);
    if (path == nullptr || path->empty()) {
      return false;
    }
    paths->push_back(Utf16FromUtf8(*path));
  }
  return !paths->empty();
}

}  // namespace

ShareChannel::ShareChannel(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kShareChannel, &flutter::StandardMethodCodec::GetInstance());
  auto* channel = channel_.get();
  sheet_ = std::make_unique<ShareSheet>(
      window, [channel](int64_t share, const std::string& event, const std::wstring& detail) {
        channel->InvokeMethod("event", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                                           {flutter::EncodableValue("share"), flutter::EncodableValue(share)},
                                           {flutter::EncodableValue("event"), flutter::EncodableValue(event)},
                                           {flutter::EncodableValue("detail"),
                                            flutter::EncodableValue(Utf8FromUtf16(detail))},
                                       }));
      });
  auto* sheet = sheet_.get();
  channel_->SetMethodCallHandler([sheet, channel, window](const flutter::MethodCall<flutter::EncodableValue>& call,
                                                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                                                      result) {
    const std::string& method = call.method_name();
    if (method == "isSupported") {
      HRESULT hr = S_OK;
      result->Success(flutter::EncodableValue(sheet->IsSupported(&hr)));
      return;
    }
    if (method == "foreground") {
      // For the tests of the desktop workflow: whether the window of the app is in front, and the class of the one
      // that is (ApplicationFrameWindow for the share window of Windows)
      HWND front = ::GetForegroundWindow();
      wchar_t name[256] = {};
      if (front != nullptr) {
        ::GetClassNameW(front, name, 255);
      }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("isApp"), flutter::EncodableValue(front != nullptr && front == window)},
          {flutter::EncodableValue("className"), flutter::EncodableValue(Utf8FromUtf16(name))},
      }));
      return;
    }
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    std::vector<std::wstring> paths;
    if (method == "shareFiles") {
      if (arguments == nullptr || !PathsOf(*arguments, &paths)) {
        result->Error("arguments", "shareFiles takes paths, a list of files");
        return;
      }
      std::wstring title;
      const auto found = arguments->find(flutter::EncodableValue("title"));
      if (found != arguments->end()) {
        if (const auto* text = std::get_if<std::string>(&found->second)) {
          title = Utf16FromUtf8(*text);
        }
      }
      if (title.empty()) {
        // Windows refuses data without a title
        title = L"Immuch360";
      }
      ShareSheet::Failure failure;
      const int64_t share = sheet->Show(paths, title, &failure);
      if (share == 0) {
        const std::string code = HexOf(failure.hr);
        const std::string text = Utf8FromUtf16(ShareSheet::MessageOf(failure.hr));
        result->Error(failure.step, text.empty() ? code : text,
                      flutter::EncodableValue(flutter::EncodableMap{
                          {flutter::EncodableValue("hresult"), flutter::EncodableValue(code)},
                          {flutter::EncodableValue("index"), flutter::EncodableValue(failure.index)},
                      }));
        return;
      }
      result->Success(flutter::EncodableValue(share));
      return;
    }
    if (method == "observeNextRequest") {
      if (arguments == nullptr || !PathsOf(*arguments, &paths)) {
        result->Error("arguments", "observeNextRequest takes paths, a list of files");
        return;
      }
      bool changed = false;
      const HRESULT hr = sheet->ObserveNextRequest(paths, [channel](double elapsed_ms, int existing) {
        channel->InvokeMethod("observed", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                                              {flutter::EncodableValue("elapsedMs"), flutter::EncodableValue(elapsed_ms)},
                                              {flutter::EncodableValue("existing"), flutter::EncodableValue(existing)},
                                          }));
      }, &changed);
      if (FAILED(hr)) {
        result->Error("window", Utf8FromUtf16(ShareSheet::MessageOf(hr)), flutter::EncodableValue(HexOf(hr)));
        return;
      }
      // Whether Windows gave another DataTransferManager than at the last share of this channel
      result->Success(flutter::EncodableValue(changed));
      return;
    }
    result->NotImplemented();
  });
}

ShareChannel::~ShareChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  // The sheet goes first: its events call the channel
  sheet_.reset();
  channel_.reset();
}
