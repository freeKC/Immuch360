#include "clipboard_channel.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr char kClipboardChannel[] = "immuch360/clipboard";

// Another program may hold the clipboard open for a moment (a clipboard
// history, a remote desktop): a few tries before giving up
constexpr int kOpenTries = 10;
constexpr DWORD kOpenWaitMs = 25;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), utf16.data(), length);
  return utf16;
}

// A movable block of the global heap holding [size] bytes of [data], as
// SetClipboardData takes it; null when there is no memory left
HGLOBAL GlobalCopy(const void* data, size_t size) {
  HGLOBAL block = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
  if (block == nullptr) {
    return nullptr;
  }
  void* target = ::GlobalLock(block);
  if (target == nullptr) {
    ::GlobalFree(block);
    return nullptr;
  }
  if (data != nullptr && size > 0) {
    std::memcpy(target, data, size);
  }
  ::GlobalUnlock(block);
  return block;
}

// The DROPFILES of [paths]: the structure, then each path in UTF-16 with its
// terminating null, then one more null
std::vector<uint8_t> DropFilesOf(const std::vector<std::wstring>& paths) {
  size_t characters = 1;
  for (const auto& path : paths) {
    characters += path.size() + 1;
  }
  std::vector<uint8_t> bytes(sizeof(DROPFILES) + characters * sizeof(wchar_t),
                             0);
  auto* drop = reinterpret_cast<DROPFILES*>(bytes.data());
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  auto* text = reinterpret_cast<wchar_t*>(bytes.data() + sizeof(DROPFILES));
  for (const auto& path : paths) {
    std::memcpy(text, path.data(), path.size() * sizeof(wchar_t));
    text += path.size() + 1;
  }
  return bytes;
}

// Puts [bytes] under [format]; false when Windows refused it (the block is
// then freed here, else the clipboard owns it)
bool SetBytes(UINT format, const void* bytes, size_t size) {
  HGLOBAL block = GlobalCopy(bytes, size);
  if (block == nullptr) {
    return false;
  }
  if (::SetClipboardData(format, block) == nullptr) {
    ::GlobalFree(block);
    return false;
  }
  return true;
}

const std::vector<uint8_t>* BytesArgument(const flutter::EncodableMap& map,
                                          const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) {
    return nullptr;
  }
  return std::get_if<std::vector<uint8_t>>(&found->second);
}

// What writeFiles does, an empty string when it succeeded, else why not
std::string WriteFiles(HWND owner, const flutter::EncodableMap& arguments) {
  const auto paths_value = arguments.find(flutter::EncodableValue("paths"));
  if (paths_value == arguments.end()) {
    return "no paths";
  }
  const auto* list = std::get_if<flutter::EncodableList>(&paths_value->second);
  if (list == nullptr || list->empty()) {
    return "no paths";
  }
  std::vector<std::wstring> paths;
  for (const auto& value : *list) {
    const auto* path = std::get_if<std::string>(&value);
    if (path == nullptr) {
      return "a path is not text";
    }
    std::wstring wide = Utf16FromUtf8(*path);
    if (wide.empty()) {
      return "a path is not UTF-8";
    }
    for (auto& character : wide) {
      if (character == L'/') {
        character = L'\\';
      }
    }
    paths.push_back(std::move(wide));
  }
  const std::vector<uint8_t> drop = DropFilesOf(paths);
  const DWORD effect = DROPEFFECT_COPY;
  const UINT drop_effect = ::RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT);
  const UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  const auto* dib = BytesArgument(arguments, "dib");
  const auto* png = BytesArgument(arguments, "png");

  bool opened = false;
  for (int attempt = 0; attempt < kOpenTries && !opened; attempt++) {
    opened = ::OpenClipboard(owner) != FALSE;
    if (!opened) {
      ::Sleep(kOpenWaitMs);
    }
  }
  if (!opened) {
    return "the clipboard is held by another program";
  }
  std::string failure;
  if (!::EmptyClipboard()) {
    failure = "the clipboard could not be emptied";
  } else if (!SetBytes(CF_HDROP, drop.data(), drop.size())) {
    failure = "the files were refused";
  } else {
    // Explorer copies the files rather than moving them; the pictures are
    // extras, the files are on the clipboard without them
    SetBytes(drop_effect, &effect, sizeof(effect));
    if (dib != nullptr && !dib->empty()) {
      SetBytes(CF_DIB, dib->data(), dib->size());
    }
    if (png != nullptr && !png->empty()) {
      SetBytes(png_format, png->data(), png->size());
    }
  }
  ::CloseClipboard();
  return failure;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateClipboardChannel(flutter::BinaryMessenger* messenger, HWND owner) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kClipboardChannel,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [owner](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "writeFiles") {
          if (arguments == nullptr) {
            result->Error("clipboard", "no arguments");
            return;
          }
          const std::string failure = WriteFiles(owner, *arguments);
          if (!failure.empty()) {
            result->Error("clipboard", failure);
            return;
          }
          result->Success(flutter::EncodableValue(
              static_cast<int64_t>(::GetClipboardSequenceNumber())));
        } else if (call.method_name() == "holds") {
          if (arguments == nullptr) {
            result->Error("clipboard", "no token");
            return;
          }
          const auto token = arguments->find(flutter::EncodableValue("token"));
          if (token == arguments->end()) {
            result->Error("clipboard", "no token");
            return;
          }
          int64_t value = 0;
          if (const auto* narrow = std::get_if<int32_t>(&token->second)) {
            value = *narrow;
          } else if (const auto* wide = std::get_if<int64_t>(&token->second)) {
            value = *wide;
          } else {
            result->Error("clipboard", "the token is not a number");
            return;
          }
          result->Success(flutter::EncodableValue(
              value == static_cast<int64_t>(::GetClipboardSequenceNumber())));
        } else {
          result->NotImplemented();
        }
      });
  return channel;
}
