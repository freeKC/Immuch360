#include "share_sheet.h"

// Must come after windows.h
#include <ShObjIdl.h>
#include <roapi.h>
#include <windows.applicationmodel.datatransfer.h>
#include <windows.foundation.collections.h>
#include <windows.foundation.h>
#include <windows.storage.h>
#include <winstring.h>
#include <wrl.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <utility>

#pragma comment(lib, "runtimeobject.lib")

namespace WRL = Microsoft::WRL;
namespace WindowsFoundation = ABI::Windows::Foundation;
namespace WindowsCollections = ABI::Windows::Foundation::Collections;
namespace WindowsStorage = ABI::Windows::Storage;
namespace DataTransfer = ABI::Windows::ApplicationModel::DataTransfer;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

// The longest a file may take to open as a StorageFile: a share of a network
// folder that no longer answers fails rather than freezing the app
constexpr ULONGLONG kOpenFileTimeoutMs = 10000;

// The task posted to the window of the messages (ShareSheet::Post)
constexpr UINT kTaskMessage = WM_APP + 0x5e;

constexpr wchar_t kMessageWindowClass[] = L"Immuch360ShareSheetMessages";

using StorageItems = std::vector<WRL::ComPtr<WindowsStorage::IStorageItem>>;
using ItemIterable = WindowsCollections::IIterable<WindowsStorage::IStorageItem*>;
using ItemIterator = WindowsCollections::IIterator<WindowsStorage::IStorageItem*>;

// The files of a share, as the data package takes them: an IIterable of
// IStorageItem, each file asked for that interface (QueryInterface), never
// cast to it
class StorageItemIterator : public WRL::RuntimeClass<ItemIterator> {
  InspectableClass(ItemIterator::z_get_rc_name_impl(), BaseTrust);

 public:
  explicit StorageItemIterator(std::shared_ptr<const StorageItems> items) : items_(std::move(items)) {}

  HRESULT STDMETHODCALLTYPE get_Current(WindowsStorage::IStorageItem** current) override {
    if (current == nullptr) {
      return E_POINTER;
    }
    *current = nullptr;
    if (position_ >= items_->size()) {
      return E_BOUNDS;
    }
    return (*items_)[position_].CopyTo(current);
  }

  HRESULT STDMETHODCALLTYPE get_HasCurrent(boolean* has_current) override {
    if (has_current == nullptr) {
      return E_POINTER;
    }
    *has_current = position_ < items_->size();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE MoveNext(boolean* has_current) override {
    if (has_current == nullptr) {
      return E_POINTER;
    }
    if (position_ >= items_->size()) {
      *has_current = false;
      return E_BOUNDS;
    }
    position_++;
    *has_current = position_ < items_->size();
    return S_OK;
  }

 private:
  std::shared_ptr<const StorageItems> items_;
  size_t position_ = 0;
};

class StorageItemList : public WRL::RuntimeClass<ItemIterable> {
  InspectableClass(ItemIterable::z_get_rc_name_impl(), BaseTrust);

 public:
  explicit StorageItemList(std::shared_ptr<const StorageItems> items) : items_(std::move(items)) {}

  HRESULT STDMETHODCALLTYPE First(ItemIterator** first) override {
    if (first == nullptr) {
      return E_POINTER;
    }
    auto iterator = WRL::Make<StorageItemIterator>(items_);
    if (!iterator) {
      *first = nullptr;
      return E_OUTOFMEMORY;
    }
    *first = iterator.Detach();
    return S_OK;
  }

 private:
  std::shared_ptr<const StorageItems> items_;
};

// The file at [path] as a storage item, waited for here: StorageFile has only
// an asynchronous open, which completes on a thread of the pool
HRESULT OpenStorageItem(const std::wstring& path, WRL::ComPtr<WindowsStorage::IStorageItem>* item) {
  WRL::ComPtr<WindowsStorage::IStorageFileStatics> statics;
  HRESULT hr = WindowsFoundation::GetActivationFactory(HStringReference(RuntimeClass_Windows_Storage_StorageFile).Get(),
                                                       &statics);
  if (FAILED(hr)) {
    return hr;
  }
  WRL::ComPtr<WindowsFoundation::IAsyncOperation<WindowsStorage::StorageFile*>> operation;
  hr = statics->GetFileFromPathAsync(HStringReference(path.c_str(), static_cast<unsigned int>(path.size())).Get(),
                                     &operation);
  if (FAILED(hr)) {
    return hr;
  }
  WRL::ComPtr<IAsyncInfo> info;
  hr = operation.As(&info);
  if (FAILED(hr)) {
    return hr;
  }
  const ULONGLONG started = ::GetTickCount64();
  AsyncStatus status = AsyncStatus::Started;
  while (SUCCEEDED(hr = info->get_Status(&status)) && status == AsyncStatus::Started) {
    if (::GetTickCount64() - started > kOpenFileTimeoutMs) {
      info->Cancel();
      return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    ::SleepEx(1, TRUE);
  }
  if (FAILED(hr)) {
    return hr;
  }
  if (status != AsyncStatus::Completed) {
    HRESULT error = E_FAIL;
    info->get_ErrorCode(&error);
    return FAILED(error) ? error : E_FAIL;
  }
  WRL::ComPtr<WindowsStorage::IStorageFile> file;
  hr = operation->GetResults(&file);
  if (FAILED(hr)) {
    return hr;
  }
  if (!file) {
    return E_UNEXPECTED;
  }
  return file.As(item);
}

std::wstring StringOf(HSTRING value) {
  unsigned int length = 0;
  const wchar_t* raw = ::WindowsGetStringRawBuffer(value, &length);
  return raw == nullptr ? std::wstring() : std::wstring(raw, length);
}

LRESULT CALLBACK MessageWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kTaskMessage) {
    auto* task = reinterpret_cast<std::function<void()>*>(lparam);
    if (task != nullptr) {
      (*task)();
      delete task;
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

HWND CreateMessageWindow() {
  static bool registered = false;
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  if (!registered) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = MessageWindowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = kMessageWindowClass;
    registered = ::RegisterClassW(&window_class) != 0 || ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }
  return ::CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
}

}  // namespace

struct ShareSheet::State : std::enable_shared_from_this<ShareSheet::State> {
  HWND window = nullptr;
  HWND messages = nullptr;
  EventHandler on_event;

  WRL::ComPtr<IDataTransferManagerInterop> interop;
  WRL::ComPtr<DataTransfer::IDataTransferManager> manager;
  EventRegistrationToken requested_token{};
  EventRegistrationToken target_token{};
  bool registered = false;

  int64_t last_share = 0;
  // The share the window has not asked the data of yet, 0 for none
  int64_t pending = 0;
  std::shared_ptr<const StorageItems> pending_items;
  std::wstring pending_title;
  // The share whose data the window took last, which a program chosen is for
  int64_t requested = 0;

  // ShowLikeSharePlus
  bool plus_pending = false;
  std::vector<std::wstring> plus_paths;
  std::function<void(int, HRESULT)> plus_on_request;

  void Post(std::function<void()> task) {
    if (messages == nullptr) {
      return;
    }
    auto* posted = new std::function<void()>(std::move(task));
    if (!::PostMessageW(messages, kTaskMessage, 0, reinterpret_cast<LPARAM>(posted))) {
      delete posted;
    }
  }

  void Emit(int64_t share, std::string event, std::wstring detail) {
    std::weak_ptr<State> weak = weak_from_this();
    Post([weak, share, event = std::move(event), detail = std::move(detail)]() {
      if (auto state = weak.lock()) {
        if (state->on_event) {
          state->on_event(share, event, detail);
        }
      }
    });
  }

  HRESULT EnsureManager(std::string* step) {
    if (manager) {
      return S_OK;
    }
    *step = "activation";
    HRESULT hr = ::RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_ApplicationModel_DataTransfer_DataTransferManager).Get(),
        IID_PPV_ARGS(&interop));
    if (FAILED(hr)) {
      return hr;
    }
    *step = "window";
    hr = interop->GetForWindow(window, IID_PPV_ARGS(&manager));
    if (FAILED(hr)) {
      manager.Reset();
      return hr;
    }
    std::weak_ptr<State> weak = weak_from_this();
    auto on_requested = WRL::Callback<WindowsFoundation::ITypedEventHandler<DataTransfer::DataTransferManager*,
                                                                            DataTransfer::DataRequestedEventArgs*>>(
        [weak](auto&&, DataTransfer::IDataRequestedEventArgs* args) -> HRESULT {
          auto state = weak.lock();
          return state ? state->OnDataRequested(args) : S_OK;
        });
    hr = manager->add_DataRequested(on_requested.Get(), &requested_token);
    if (FAILED(hr)) {
      manager.Reset();
      return hr;
    }
    auto on_target = WRL::Callback<WindowsFoundation::ITypedEventHandler<
        DataTransfer::DataTransferManager*, DataTransfer::TargetApplicationChosenEventArgs*>>(
        [weak](auto&&, DataTransfer::ITargetApplicationChosenEventArgs* args) -> HRESULT {
          auto state = weak.lock();
          if (!state || args == nullptr) {
            return S_OK;
          }
          HSTRING name = nullptr;
          std::wstring chosen;
          if (SUCCEEDED(args->get_ApplicationName(&name))) {
            chosen = StringOf(name);
            ::WindowsDeleteString(name);
          }
          state->Emit(state->requested, "target", chosen);
          return S_OK;
        });
    // Without this event the share still works: only the name of the program is not known
    manager->add_TargetApplicationChosen(on_target.Get(), &target_token);
    registered = true;
    return S_OK;
  }

  HRESULT OnDataRequested(DataTransfer::IDataRequestedEventArgs* args) {
    if (args == nullptr) {
      return E_POINTER;
    }
    WRL::ComPtr<DataTransfer::IDataRequest> request;
    HRESULT hr = args->get_Request(&request);
    if (FAILED(hr)) {
      return hr;
    }
    if (plus_pending) {
      return OnDataRequestedLikeSharePlus(request.Get());
    }
    if (pending == 0) {
      // A request with no share asked: Windows shows that there is nothing to share
      return request->FailWithDisplayText(HStringReference(L"Nothing to share").Get());
    }
    const int64_t share = pending;
    auto items = std::move(pending_items);
    const std::wstring title = std::move(pending_title);
    pending = 0;
    pending_items.reset();

    WRL::ComPtr<DataTransfer::IDataPackage> data;
    hr = request->get_Data(&data);
    if (FAILED(hr)) {
      return hr;
    }
    WRL::ComPtr<DataTransfer::IDataPackagePropertySet> properties;
    if (SUCCEEDED(data->get_Properties(&properties))) {
      // The title is mandatory: without it Windows refuses the data
      properties->put_Title(HStringReference(title.c_str(), static_cast<unsigned int>(title.size())).Get());
    }
    auto list = WRL::Make<StorageItemList>(items);
    if (!list) {
      return E_OUTOFMEMORY;
    }
    hr = data->SetStorageItemsReadOnly(list.Get());
    if (FAILED(hr)) {
      return hr;
    }
    requested = share;

    std::weak_ptr<State> weak = weak_from_this();
    auto on_completed = WRL::Callback<WindowsFoundation::ITypedEventHandler<
        DataTransfer::DataPackage*, DataTransfer::OperationCompletedEventArgs*>>(
        [weak, share](auto&&, DataTransfer::IOperationCompletedEventArgs* completed) -> HRESULT {
          auto state = weak.lock();
          if (!state) {
            return S_OK;
          }
          auto operation = static_cast<DataTransfer::DataPackageOperation>(0);
          if (completed != nullptr) {
            completed->get_Operation(&operation);
          }
          state->Emit(share, "completed", std::to_wstring(static_cast<int>(operation)));
          return S_OK;
        });
    EventRegistrationToken completed_token{};
    data->add_OperationCompleted(on_completed.Get(), &completed_token);
    auto on_destroyed =
        WRL::Callback<WindowsFoundation::ITypedEventHandler<DataTransfer::DataPackage*, IInspectable*>>(
            [weak, share](auto&&, auto&&) -> HRESULT {
              if (auto state = weak.lock()) {
                state->Emit(share, "destroyed", std::wstring());
              }
              return S_OK;
            });
    EventRegistrationToken destroyed_token{};
    data->add_Destroyed(on_destroyed.Get(), &destroyed_token);

    Emit(share, "requested", std::to_wstring(items ? items->size() : 0));
    return S_OK;
  }

  HRESULT OnDataRequestedLikeSharePlus(DataTransfer::IDataRequest* request) {
    plus_pending = false;
    auto paths = std::move(plus_paths);
    auto on_request = std::move(plus_on_request);
    WRL::ComPtr<DataTransfer::IDataPackage> data;
    HRESULT hr = request->get_Data(&data);
    if (FAILED(hr)) {
      return hr;
    }
    WRL::ComPtr<DataTransfer::IDataPackagePropertySet> properties;
    if (SUCCEEDED(data->get_Properties(&properties)) && !paths.empty()) {
      properties->put_Title(
          HStringReference(paths.front().c_str(), static_cast<unsigned int>(paths.front().size())).Get());
    }
    // As share_plus 10.1.4: each path opened now, the ones that fail left out
    auto items = std::make_shared<StorageItems>();
    HRESULT first_error = S_OK;
    for (const auto& path : paths) {
      WRL::ComPtr<WindowsStorage::IStorageItem> item;
      HRESULT opened = OpenStorageItem(path, &item);
      if (SUCCEEDED(opened)) {
        items->push_back(item);
      } else if (SUCCEEDED(first_error)) {
        first_error = opened;
      }
    }
    auto list = WRL::Make<StorageItemList>(items);
    if (list) {
      data->SetStorageItemsReadOnly(list.Get());
    }
    const int opened_count = static_cast<int>(items->size());
    if (on_request) {
      Post([on_request, opened_count, first_error]() { on_request(opened_count, first_error); });
    }
    return S_OK;
  }
};

ShareSheet::ShareSheet(HWND window, EventHandler on_event) : state_(std::make_shared<State>()) {
  state_->window = window;
  state_->on_event = std::move(on_event);
  state_->messages = CreateMessageWindow();
}

ShareSheet::~ShareSheet() {
  if (state_->manager && state_->registered) {
    state_->manager->remove_DataRequested(state_->requested_token);
    state_->manager->remove_TargetApplicationChosen(state_->target_token);
  }
  state_->manager.Reset();
  state_->interop.Reset();
  if (state_->messages != nullptr) {
    ::DestroyWindow(state_->messages);
    state_->messages = nullptr;
  }
}

bool ShareSheet::IsSupported(HRESULT* hr) {
  WRL::ComPtr<DataTransfer::IDataTransferManagerStatics2> statics;
  HRESULT result = ::RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_ApplicationModel_DataTransfer_DataTransferManager).Get(),
      IID_PPV_ARGS(&statics));
  boolean supported = false;
  if (SUCCEEDED(result)) {
    result = statics->IsSupported(&supported);
  }
  if (hr != nullptr) {
    *hr = result;
  }
  return SUCCEEDED(result) && supported;
}

int64_t ShareSheet::Show(const std::vector<std::wstring>& paths, const std::wstring& title, Failure* failure) {
  Failure ignored;
  Failure* out = failure != nullptr ? failure : &ignored;
  std::string step;
  HRESULT hr = state_->EnsureManager(&step);
  if (FAILED(hr)) {
    *out = Failure{step, hr, -1};
    return 0;
  }
  auto items = std::make_shared<StorageItems>();
  for (size_t index = 0; index < paths.size(); index++) {
    WRL::ComPtr<WindowsStorage::IStorageItem> item;
    hr = OpenStorageItem(paths[index], &item);
    if (FAILED(hr)) {
      *out = Failure{"file", hr, static_cast<int>(index)};
      return 0;
    }
    items->push_back(item);
  }
  const int64_t share = ++state_->last_share;
  state_->plus_pending = false;
  state_->pending = share;
  state_->pending_items = items;
  state_->pending_title = title;
  hr = state_->interop->ShowShareUIForWindow(state_->window);
  if (FAILED(hr)) {
    state_->pending = 0;
    state_->pending_items.reset();
    *out = Failure{"show", hr, -1};
    return 0;
  }
  return share;
}

HRESULT ShareSheet::ShowLikeSharePlus(const std::vector<std::wstring>& paths,
                                      std::function<void(int opened, HRESULT first_error)> on_request) {
  std::string step;
  HRESULT hr = state_->EnsureManager(&step);
  if (FAILED(hr)) {
    return hr;
  }
  state_->pending = 0;
  state_->pending_items.reset();
  state_->plus_pending = true;
  state_->plus_paths = paths;
  state_->plus_on_request = std::move(on_request);
  hr = state_->interop->ShowShareUIForWindow(state_->window);
  if (FAILED(hr)) {
    state_->plus_pending = false;
  }
  return hr;
}

void ShareSheet::Post(std::function<void()> task) { state_->Post(std::move(task)); }

std::wstring ShareSheet::MessageOf(HRESULT hr) {
  wchar_t* buffer = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
      static_cast<DWORD>(hr), MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US), reinterpret_cast<wchar_t*>(&buffer), 0,
      nullptr);
  if (length == 0 || buffer == nullptr) {
    // No English text on this system: its own language then
    if (::FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                         nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr) == 0 ||
        buffer == nullptr) {
      return std::wstring();
    }
  }
  std::wstring message(buffer);
  ::LocalFree(buffer);
  while (!message.empty() && (message.back() == L'\r' || message.back() == L'\n' || message.back() == L' ')) {
    message.pop_back();
  }
  return message;
}
