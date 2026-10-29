#include "gpu_probe.h"

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// The probe of the graphics cards (gpu_probe.h). It loads the Vulkan loader
// of the system (libvulkan.so.1, never shipped by the app), makes an instance
// without any logical device, so that nothing is allocated on a card, and
// writes for each physical device what the gate of the panoramas and
// stable-diffusion.cpp look at: its name, its kind, its vendor and device ids,
// the versions of its driver and of its Vulkan, the memory local to it and,
// with VK_EXT_memory_budget, the budget the system gives and what is used of
// it; its UUID, LUID, driver id and 16 bit storage, by which the app tells the
// index ggml gives the card. The JSON is the one GpuReport.fromJson reads
// (lib/desktop/ai/engine/backends.dart). The probe of Windows
// (windows/runner/gpu_probe.cpp) is the same with the adapters of DXGI: a
// change to one goes to the other.

namespace {

constexpr char kFlag[] = "--immuch360-gpu-probe=";

// Past this the probe ends itself (SIGALRM), a driver that hangs included;
// the app stops waiting for it at the same time
constexpr unsigned kLimitSeconds = 10;

// The exit code besides 0: the JSON could not be written
constexpr int kExitNotWritten = 2;

// The declarations of the Vulkan API the probe needs, after vulkan_core.h of
// the Khronos Group (Apache 2.0 or MIT), so that the build needs no Vulkan
// SDK or headers. Their sizes are those of the headers on x64, checked below.
using VkBool32 = uint32_t;
using VkDeviceSize = uint64_t;
using VkResult = int32_t;
using VkStructureType = int32_t;
struct VkInstanceT;
struct VkPhysicalDeviceT;
using VkInstance = VkInstanceT*;
using VkPhysicalDevice = VkPhysicalDeviceT*;

constexpr VkResult kVkSuccess = 0;
constexpr VkResult kVkIncomplete = 5;
constexpr VkStructureType kApplicationInfo = 0;
constexpr VkStructureType kInstanceCreateInfo = 1;
constexpr VkStructureType kPhysicalDeviceFeatures2 = 1000059000;
constexpr VkStructureType kPhysicalDeviceProperties2 = 1000059001;
constexpr VkStructureType kPhysicalDeviceMemoryProperties2 = 1000059006;
constexpr VkStructureType kPhysicalDeviceIdProperties = 1000071004;
constexpr VkStructureType kPhysicalDevice16BitStorageFeatures = 1000083000;
constexpr VkStructureType kPhysicalDeviceDriverProperties = 1000196000;
constexpr VkStructureType kPhysicalDeviceMemoryBudgetProperties = 1000237000;
constexpr uint32_t kMemoryHeapDeviceLocal = 0x1;
constexpr uint32_t kMaxMemoryHeaps = 16;

constexpr uint32_t VkVersion(uint32_t major, uint32_t minor) {
  return (major << 22) | (minor << 12);
}

struct VkApplicationInfo {
  VkStructureType sType;
  const void* pNext;
  const char* pApplicationName;
  uint32_t applicationVersion;
  const char* pEngineName;
  uint32_t engineVersion;
  uint32_t apiVersion;
};

struct VkInstanceCreateInfo {
  VkStructureType sType;
  const void* pNext;
  uint32_t flags;
  const VkApplicationInfo* pApplicationInfo;
  uint32_t enabledLayerCount;
  const char* const* ppEnabledLayerNames;
  uint32_t enabledExtensionCount;
  const char* const* ppEnabledExtensionNames;
};

// VkPhysicalDeviceLimits (504 bytes, aligned on 8 by its VkDeviceSize) and
// VkPhysicalDeviceSparseProperties are not read: only their room
struct VkPhysicalDeviceProperties {
  uint32_t apiVersion;
  uint32_t driverVersion;
  uint32_t vendorID;
  uint32_t deviceID;
  int32_t deviceType;
  char deviceName[256];
  uint8_t pipelineCacheUUID[16];
  uint64_t limits[63];
  uint8_t sparseProperties[20];
};

struct VkPhysicalDeviceProperties2 {
  VkStructureType sType;
  void* pNext;
  VkPhysicalDeviceProperties properties;
};

struct VkPhysicalDeviceIDProperties {
  VkStructureType sType;
  void* pNext;
  uint8_t deviceUUID[16];
  uint8_t driverUUID[16];
  uint8_t deviceLUID[8];
  uint32_t deviceNodeMask;
  VkBool32 deviceLUIDValid;
};

struct VkPhysicalDeviceDriverProperties {
  VkStructureType sType;
  void* pNext;
  int32_t driverID;
  char driverName[256];
  char driverInfo[256];
  uint8_t conformanceVersion[4];
};

struct VkMemoryType {
  uint32_t propertyFlags;
  uint32_t heapIndex;
};

struct VkMemoryHeap {
  VkDeviceSize size;
  uint32_t flags;
};

struct VkPhysicalDeviceMemoryProperties {
  uint32_t memoryTypeCount;
  VkMemoryType memoryTypes[32];
  uint32_t memoryHeapCount;
  VkMemoryHeap memoryHeaps[kMaxMemoryHeaps];
};

struct VkPhysicalDeviceMemoryProperties2 {
  VkStructureType sType;
  void* pNext;
  VkPhysicalDeviceMemoryProperties memoryProperties;
};

struct VkPhysicalDeviceMemoryBudgetPropertiesEXT {
  VkStructureType sType;
  void* pNext;
  VkDeviceSize heapBudget[kMaxMemoryHeaps];
  VkDeviceSize heapUsage[kMaxMemoryHeaps];
};

struct VkPhysicalDevice16BitStorageFeatures {
  VkStructureType sType;
  void* pNext;
  VkBool32 storageBuffer16BitAccess;
  VkBool32 uniformAndStorageBuffer16BitAccess;
  VkBool32 storagePushConstant16;
  VkBool32 storageInputOutput16;
};

// VkPhysicalDeviceFeatures: 55 VkBool32, not read
struct VkPhysicalDeviceFeatures2 {
  VkStructureType sType;
  void* pNext;
  VkBool32 features[55];
};

struct VkExtensionProperties {
  char extensionName[256];
  uint32_t specVersion;
};

static_assert(sizeof(VkApplicationInfo) == 48, "VkApplicationInfo");
static_assert(sizeof(VkInstanceCreateInfo) == 64, "VkInstanceCreateInfo");
static_assert(sizeof(VkPhysicalDeviceProperties) == 824,
              "VkPhysicalDeviceProperties");
static_assert(offsetof(VkPhysicalDeviceProperties, limits) == 296,
              "VkPhysicalDeviceLimits");
static_assert(sizeof(VkPhysicalDeviceProperties2) == 840,
              "VkPhysicalDeviceProperties2");
static_assert(sizeof(VkPhysicalDeviceIDProperties) == 64,
              "VkPhysicalDeviceIDProperties");
static_assert(sizeof(VkPhysicalDeviceDriverProperties) == 536,
              "VkPhysicalDeviceDriverProperties");
static_assert(sizeof(VkPhysicalDeviceMemoryProperties) == 520,
              "VkPhysicalDeviceMemoryProperties");
static_assert(sizeof(VkPhysicalDeviceMemoryProperties2) == 536,
              "VkPhysicalDeviceMemoryProperties2");
static_assert(sizeof(VkPhysicalDeviceMemoryBudgetPropertiesEXT) == 272,
              "VkPhysicalDeviceMemoryBudgetPropertiesEXT");
static_assert(sizeof(VkPhysicalDevice16BitStorageFeatures) == 32,
              "VkPhysicalDevice16BitStorageFeatures");
static_assert(sizeof(VkPhysicalDeviceFeatures2) == 240,
              "VkPhysicalDeviceFeatures2");
static_assert(sizeof(VkExtensionProperties) == 260, "VkExtensionProperties");

using PFN_vkVoidFunction = void(*)();
using PFN_vkGetInstanceProcAddr =
    PFN_vkVoidFunction(*)(VkInstance, const char*);
using PFN_vkEnumerateInstanceVersion = VkResult(*)(uint32_t*);
using PFN_vkCreateInstance = VkResult(*)(const VkInstanceCreateInfo*,
                                                  const void*, VkInstance*);
using PFN_vkDestroyInstance = void(*)(VkInstance, const void*);
using PFN_vkEnumeratePhysicalDevices = VkResult(*)(VkInstance,
                                                            uint32_t*,
                                                            VkPhysicalDevice*);
using PFN_vkGetPhysicalDeviceProperties =
    void(*)(VkPhysicalDevice, VkPhysicalDeviceProperties*);
using PFN_vkGetPhysicalDeviceProperties2 =
    void(*)(VkPhysicalDevice, VkPhysicalDeviceProperties2*);
using PFN_vkGetPhysicalDeviceMemoryProperties =
    void(*)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
using PFN_vkGetPhysicalDeviceMemoryProperties2 =
    void(*)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties2*);
using PFN_vkGetPhysicalDeviceFeatures2 =
    void(*)(VkPhysicalDevice, VkPhysicalDeviceFeatures2*);
using PFN_vkEnumerateDeviceExtensionProperties = VkResult(*)(
    VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*);

// One adapter as the JSON tells it; an empty string or a negative number is
// written as null
struct Adapter {
  std::string name;
  const char* type = "other";
  uint64_t local_memory = 0;
  bool has_budget = false;
  uint64_t budget = 0;
  uint64_t usage = 0;
  uint32_t vendor_id = 0;
  uint32_t device_id = 0;
  std::string driver_version;
  std::string api_version;
  const char* source = "vulkan";
  int vulkan_index = -1;
  std::string uuid;
  std::string luid;
  int driver_id = -1;
  int storage_16bit = -1;
};

// What the probe found
struct Report {
  std::string instance_version;
  std::vector<Adapter> adapters;
  // Null, or "noVulkan" when the system has no Vulkan loader or no driver
  const char* problem = nullptr;
};

std::string Hex(const uint8_t* bytes, size_t length) {
  static const char kDigits[] = "0123456789abcdef";
  std::string text;
  for (size_t i = 0; i < length; i++) {
    text.push_back(kDigits[bytes[i] >> 4]);
    text.push_back(kDigits[bytes[i] & 0xF]);
  }
  return text;
}

// "1.4.312", a version as Vulkan packs it
std::string VulkanVersion(uint32_t version) {
  return std::to_string((version >> 22) & 0x7F) + "." +
         std::to_string((version >> 12) & 0x3FF) + "." +
         std::to_string(version & 0xFFF);
}

// The driver version as its vendor shows it: "580.95" for NVIDIA, the Vulkan
// packing for the others (Mesa)
std::string DriverVersion(uint32_t vendor, uint32_t version) {
  if (vendor == 0x10DE) {
    return std::to_string((version >> 22) & 0x3FF) + "." +
           std::to_string((version >> 14) & 0xFF);
  }
  return VulkanVersion(version);
}

const char* DeviceType(int32_t type) {
  switch (type) {
    case 1:
      return "integrated";
    case 2:
      return "discrete";
    case 3:
      return "virtual";
    case 4:
      return "cpu";
    default:
      return "other";
  }
}

bool HasExtension(const std::vector<VkExtensionProperties>& extensions,
                  const char* name) {
  for (const VkExtensionProperties& extension : extensions) {
    if (std::strncmp(extension.extensionName, name,
                     sizeof(extension.extensionName)) == 0) {
      return true;
    }
  }
  return false;
}

template <typename Function>
Function Load(PFN_vkGetInstanceProcAddr get, VkInstance instance,
              const char* name) {
  return reinterpret_cast<Function>(get(instance, name));
}

// The functions of an instance the probe calls; those of Vulkan 1.1 null on
// an instance of 1.0
struct InstanceFunctions {
  PFN_vkGetPhysicalDeviceProperties properties = nullptr;
  PFN_vkGetPhysicalDeviceProperties2 properties2 = nullptr;
  PFN_vkGetPhysicalDeviceMemoryProperties memory = nullptr;
  PFN_vkGetPhysicalDeviceMemoryProperties2 memory2 = nullptr;
  PFN_vkGetPhysicalDeviceFeatures2 features2 = nullptr;
  PFN_vkEnumerateDeviceExtensionProperties extensions = nullptr;
};

Adapter ReadDevice(const InstanceFunctions& vk, VkPhysicalDevice device,
                   int index) {
  Adapter adapter;
  adapter.vulkan_index = index;
  VkPhysicalDeviceProperties properties = {};
  vk.properties(device, &properties);
  properties.deviceName[sizeof(properties.deviceName) - 1] = '\0';
  adapter.name = properties.deviceName;
  adapter.type = DeviceType(properties.deviceType);
  adapter.vendor_id = properties.vendorID;
  adapter.device_id = properties.deviceID;
  adapter.api_version = VulkanVersion(properties.apiVersion);
  adapter.driver_version =
      DriverVersion(properties.vendorID, properties.driverVersion);

  std::vector<VkExtensionProperties> extensions;
  uint32_t count = 0;
  if (vk.extensions(device, nullptr, &count, nullptr) == kVkSuccess &&
      count > 0) {
    extensions.resize(count);
    const VkResult listed =
        vk.extensions(device, nullptr, &count, extensions.data());
    extensions.resize(listed == kVkSuccess || listed == kVkIncomplete ? count
                                                                      : 0);
  }
  // Queries of Vulkan 1.1 only on a device and an instance of 1.1
  const bool core11 = properties.apiVersion >= VkVersion(1, 1) &&
                      vk.properties2 != nullptr && vk.memory2 != nullptr &&
                      vk.features2 != nullptr;
  const bool has_budget =
      core11 && HasExtension(extensions, "VK_EXT_memory_budget");
  const bool has_driver =
      core11 && (properties.apiVersion >= VkVersion(1, 2) ||
                 HasExtension(extensions, "VK_KHR_driver_properties"));

  VkPhysicalDeviceMemoryProperties memory = {};
  VkPhysicalDeviceMemoryBudgetPropertiesEXT budget = {};
  if (core11) {
    VkPhysicalDeviceDriverProperties driver = {};
    driver.sType = kPhysicalDeviceDriverProperties;
    VkPhysicalDeviceIDProperties id = {};
    id.sType = kPhysicalDeviceIdProperties;
    id.pNext = has_driver ? &driver : nullptr;
    VkPhysicalDeviceProperties2 properties2 = {};
    properties2.sType = kPhysicalDeviceProperties2;
    properties2.pNext = &id;
    vk.properties2(device, &properties2);
    adapter.uuid = Hex(id.deviceUUID, sizeof(id.deviceUUID));
    if (id.deviceLUIDValid) {
      adapter.luid = Hex(id.deviceLUID, sizeof(id.deviceLUID));
    }
    if (has_driver) {
      adapter.driver_id = driver.driverID;
    }

    VkPhysicalDevice16BitStorageFeatures storage = {};
    storage.sType = kPhysicalDevice16BitStorageFeatures;
    VkPhysicalDeviceFeatures2 features = {};
    features.sType = kPhysicalDeviceFeatures2;
    features.pNext = &storage;
    vk.features2(device, &features);
    adapter.storage_16bit = storage.storageBuffer16BitAccess ? 1 : 0;

    VkPhysicalDeviceMemoryProperties2 memory2 = {};
    memory2.sType = kPhysicalDeviceMemoryProperties2;
    if (has_budget) {
      budget.sType = kPhysicalDeviceMemoryBudgetProperties;
      memory2.pNext = &budget;
    }
    vk.memory2(device, &memory2);
    memory = memory2.memoryProperties;
  } else {
    vk.memory(device, &memory);
  }

  // The heaps local to the device, as ggml counts them: their sizes, and the
  // budget of each (never above its size) and what is used of it
  const uint32_t heaps = memory.memoryHeapCount < kMaxMemoryHeaps
                             ? memory.memoryHeapCount
                             : kMaxMemoryHeaps;
  for (uint32_t heap = 0; heap < heaps; heap++) {
    if ((memory.memoryHeaps[heap].flags & kMemoryHeapDeviceLocal) == 0) {
      continue;
    }
    const VkDeviceSize size = memory.memoryHeaps[heap].size;
    adapter.local_memory += size;
    if (has_budget) {
      adapter.budget +=
          budget.heapBudget[heap] < size ? budget.heapBudget[heap] : size;
      adapter.usage += budget.heapUsage[heap];
    }
  }
  adapter.has_budget = has_budget;
  return adapter;
}

void ReadVulkan(Report* report) {
  // The loader of the system, by its soname
  void* library = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    report->problem = "noVulkan";
    return;
  }
  // Left loaded: the process ends right after
  const auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
      dlsym(library, "vkGetInstanceProcAddr"));
  if (get == nullptr) {
    report->problem = "noVulkan";
    return;
  }
  uint32_t loader = VkVersion(1, 0);
  const auto version = Load<PFN_vkEnumerateInstanceVersion>(
      get, nullptr, "vkEnumerateInstanceVersion");
  if (version == nullptr || version(&loader) != kVkSuccess) {
    loader = VkVersion(1, 0);
  }
  report->instance_version = VulkanVersion(loader);

  const uint32_t api =
      loader >= VkVersion(1, 1) ? VkVersion(1, 1) : VkVersion(1, 0);
  VkApplicationInfo application = {kApplicationInfo,
                                   nullptr,
                                   "immuch360-gpu-probe",
                                   1,
                                   nullptr,
                                   0,
                                   api};
  VkInstanceCreateInfo create_info = {kInstanceCreateInfo, nullptr, 0,
                                      &application,        0,       nullptr,
                                      0,                   nullptr};
  const auto create =
      Load<PFN_vkCreateInstance>(get, nullptr, "vkCreateInstance");
  VkInstance instance = nullptr;
  if (create == nullptr ||
      create(&create_info, nullptr, &instance) != kVkSuccess ||
      instance == nullptr) {
    report->problem = "noVulkan";
    return;
  }

  InstanceFunctions vk;
  vk.properties = Load<PFN_vkGetPhysicalDeviceProperties>(
      get, instance, "vkGetPhysicalDeviceProperties");
  vk.memory = Load<PFN_vkGetPhysicalDeviceMemoryProperties>(
      get, instance, "vkGetPhysicalDeviceMemoryProperties");
  vk.extensions = Load<PFN_vkEnumerateDeviceExtensionProperties>(
      get, instance, "vkEnumerateDeviceExtensionProperties");
  if (api >= VkVersion(1, 1)) {
    vk.properties2 = Load<PFN_vkGetPhysicalDeviceProperties2>(
        get, instance, "vkGetPhysicalDeviceProperties2");
    vk.memory2 = Load<PFN_vkGetPhysicalDeviceMemoryProperties2>(
        get, instance, "vkGetPhysicalDeviceMemoryProperties2");
    vk.features2 = Load<PFN_vkGetPhysicalDeviceFeatures2>(
        get, instance, "vkGetPhysicalDeviceFeatures2");
  }
  const auto enumerate = Load<PFN_vkEnumeratePhysicalDevices>(
      get, instance, "vkEnumeratePhysicalDevices");
  const auto destroy =
      Load<PFN_vkDestroyInstance>(get, instance, "vkDestroyInstance");

  if (enumerate != nullptr && vk.properties != nullptr &&
      vk.memory != nullptr && vk.extensions != nullptr) {
    uint32_t count = 0;
    std::vector<VkPhysicalDevice> devices;
    if (enumerate(instance, &count, nullptr) == kVkSuccess && count > 0) {
      devices.resize(count);
      const VkResult listed = enumerate(instance, &count, devices.data());
      devices.resize(listed == kVkSuccess || listed == kVkIncomplete ? count
                                                                     : 0);
    }
    for (size_t index = 0; index < devices.size(); index++) {
      report->adapters.push_back(
          ReadDevice(vk, devices[index], static_cast<int>(index)));
    }
  }
  if (destroy != nullptr) {
    destroy(instance, nullptr);
  }
}

void AppendString(std::string* json, const std::string& text) {
  json->push_back('"');
  for (const char c : text) {
    const unsigned char byte = static_cast<unsigned char>(c);
    if (c == '"' || c == '\\') {
      json->push_back('\\');
      json->push_back(c);
    } else if (byte < 0x20) {
      char escaped[8];
      std::snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
      json->append(escaped);
    } else {
      json->push_back(c);
    }
  }
  json->push_back('"');
}

void AppendName(std::string* json, const char* name) {
  json->push_back('"');
  json->append(name);
  json->append("\":");
}

void AppendText(std::string* json, const char* name, const std::string& text) {
  AppendName(json, name);
  if (text.empty()) {
    json->append("null");
  } else {
    AppendString(json, text);
  }
  json->push_back(',');
}

void AppendNumber(std::string* json, const char* name, uint64_t value) {
  AppendName(json, name);
  json->append(std::to_string(value));
  json->push_back(',');
}

void AppendOptional(std::string* json, const char* name, bool known,
                    uint64_t value) {
  AppendName(json, name);
  json->append(known ? std::to_string(value) : "null");
  json->push_back(',');
}

std::string ToJson(const Report& report) {
  std::string json = "{";
  AppendText(&json, "instanceVersion", report.instance_version);
  json.append("\"adapters\":[");
  for (size_t i = 0; i < report.adapters.size(); i++) {
    const Adapter& adapter = report.adapters[i];
    json.append(i == 0 ? "{" : ",{");
    AppendText(&json, "name", adapter.name);
    AppendText(&json, "type", adapter.type);
    AppendNumber(&json, "localMemory", adapter.local_memory);
    AppendNumber(&json, "vendorId", adapter.vendor_id);
    AppendNumber(&json, "deviceId", adapter.device_id);
    AppendText(&json, "driverVersion", adapter.driver_version);
    AppendText(&json, "apiVersion", adapter.api_version);
    AppendOptional(&json, "budget", adapter.has_budget, adapter.budget);
    AppendOptional(&json, "usage", adapter.has_budget, adapter.usage);
    AppendOptional(&json, "vulkanIndex", adapter.vulkan_index >= 0,
                   static_cast<uint64_t>(adapter.vulkan_index));
    AppendText(&json, "uuid", adapter.uuid);
    AppendText(&json, "luid", adapter.luid);
    AppendOptional(&json, "driverId", adapter.driver_id >= 0,
                   static_cast<uint64_t>(adapter.driver_id));
    AppendName(&json, "storage16Bit");
    json.append(adapter.storage_16bit < 0
                    ? "null"
                    : (adapter.storage_16bit == 1 ? "true" : "false"));
    json.push_back(',');
    AppendName(&json, "source");
    AppendString(&json, adapter.source);
    json.push_back('}');
  }
  json.append("],");
  AppendName(&json, "problem");
  if (report.problem == nullptr) {
    json.append("null");
  } else {
    AppendString(&json, report.problem);
  }
  json.append("}\n");
  return json;
}

}  // namespace

const char* GpuProbeOutput(int argc, char** argv) {
  const size_t flag_length = std::strlen(kFlag);
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], kFlag, flag_length) == 0 &&
        argv[i][flag_length] != '\0') {
      return argv[i] + flag_length;
    }
  }
  return nullptr;
}

int RunGpuProbe(const char* output) {
  // Its default action ends the process, even if the app ignored it
  signal(SIGALRM, SIG_DFL);
  alarm(kLimitSeconds);

  Report report;
  ReadVulkan(&report);
  const std::string json = ToJson(report);

  FILE* file = std::fopen(output, "wb");
  if (file == nullptr) {
    return kExitNotWritten;
  }
  const size_t written = std::fwrite(json.data(), 1, json.size(), file);
  const bool closed = std::fclose(file) == 0;
  return written == json.size() && closed ? 0 : kExitNotWritten;
}
