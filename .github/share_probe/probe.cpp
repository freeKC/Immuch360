// Probe of the share window of Windows for an unpackaged Win32 program, on the hosted runners: what
// DataTransferManager answers, whether and when the window asks for its data, and what a file deleted at once
// (as the share of desktop build 35 deletes it) leaves in the data package.
//   probe.exe <scenario> <file> <seconds>
// scenario: ours (files opened before the window shows), plus (share_plus 10.1.4: files opened on request),
// plusdeleted (the same, the file deleted as soon as the show returned)
#include <windows.h>

#include <cstdio>
#include <string>

#include "share_sheet.h"

namespace {

ULONGLONG g_start = 0;

double Now() { return static_cast<double>(::GetTickCount64() - g_start) / 1000.0; }

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
                                           nullptr, nullptr);
  std::string out(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), out.data(), length, nullptr,
                        nullptr);
  return out;
}

void Line(const char* what, const std::string& detail) {
  std::printf("{\"t\": %.3f, \"what\": \"%s\", \"detail\": \"%s\"}\n", Now(), what, detail.c_str());
  std::fflush(stdout);
}

std::string Hex(HRESULT hr) {
  char buffer[16];
  std::snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(hr));
  return buffer;
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_DESTROY) {
    ::PostQuitMessage(0);
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  g_start = ::GetTickCount64();
  if (argc < 4) {
    std::printf("usage: probe.exe ours|plus|plusdeleted <file> <seconds>\n");
    return 2;
  }
  const std::wstring scenario = argv[1];
  const std::wstring file = argv[2];
  const int seconds = _wtoi(argv[3]);
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"Immuch360ShareProbe";
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  ::RegisterClassW(&window_class);
  HWND window = ::CreateWindowExW(0, window_class.lpszClassName, L"Immuch360 share probe", WS_OVERLAPPEDWINDOW,
                                  100, 100, 800, 600, nullptr, nullptr, window_class.hInstance, nullptr);
  ::ShowWindow(window, SW_SHOW);
  ::SetForegroundWindow(window);
  ::UpdateWindow(window);
  Line("window", window != nullptr ? "created" : "failed");

  {
    ShareSheet sheet(window, [](int64_t share, const std::string& event, const std::wstring& detail) {
      Line(event.c_str(), "share " + std::to_string(share) + ": " + Narrow(detail));
    });
    HRESULT supported_hr = S_OK;
    const bool supported = sheet.IsSupported(&supported_hr);
    Line("isSupported", std::string(supported ? "true" : "false") + " " + Hex(supported_hr));

    if (scenario == L"ours") {
      ShareSheet::Failure failure;
      const int64_t share = sheet.Show({file}, L"probe.txt", &failure);
      if (share == 0) {
        Line("showFailed", failure.step + " " + Hex(failure.hr) + " " + Narrow(ShareSheet::MessageOf(failure.hr)));
      } else {
        Line("shown", "share " + std::to_string(share));
      }
    } else {
      const bool remove = scenario == L"plusdeleted";
      HRESULT hr = sheet.ShowLikeSharePlus({file}, [](int opened, HRESULT first_error) {
        Line("plusRequested", "opened " + std::to_string(opened) + " first error " + Hex(first_error) + " " +
                                  Narrow(ShareSheet::MessageOf(first_error)));
      });
      Line("plusShown", Hex(hr) + " " + Narrow(ShareSheet::MessageOf(hr)));
      if (remove) {
        const BOOL deleted = ::DeleteFileW(file.c_str());
        Line("deleted", deleted ? "yes" : "no " + std::to_string(::GetLastError()));
      }
    }

    const ULONGLONG until = ::GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000;
    bool escaped = false;
    MSG msg;
    while (::GetTickCount64() < until) {
      while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
      }
      if (!escaped && ::GetTickCount64() + 5000 > until) {
        // Close what the share window left open, from the keyboard as a user would
        HWND front = ::GetForegroundWindow();
        wchar_t title[256] = {};
        wchar_t name[256] = {};
        ::GetWindowTextW(front, title, 255);
        ::GetClassNameW(front, name, 255);
        Line("foreground", Narrow(title) + " | " + Narrow(name));
        INPUT keys[2] = {};
        keys[0].type = INPUT_KEYBOARD;
        keys[0].ki.wVk = VK_ESCAPE;
        keys[1].type = INPUT_KEYBOARD;
        keys[1].ki.wVk = VK_ESCAPE;
        keys[1].ki.dwFlags = KEYEVENTF_KEYUP;
        ::SendInput(2, keys, sizeof(INPUT));
        escaped = true;
      }
      ::MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
    }
  }
  Line("end", "");
  ::DestroyWindow(window);
  return 0;
}
