// A libnvidia-ml.so.1 for gpu_probe_nvml_test.dart: one NVIDIA card, and process lists that say of the app's process
// (pid 4242) what FAKE_NVML asks, as the drivers do: a figure, no entry, or an entry without a figure
// (NVML_VALUE_NOT_AVAILABLE). Only the functions the Linux probe calls, with the layout of nvmlProcessInfo_t.

#include <stdlib.h>
#include <string.h>

typedef struct {
  unsigned int pid;
  unsigned long long usedGpuMemory;
  unsigned int gpuInstanceId;
  unsigned int computeInstanceId;
} ProcessInfo;

#define NOT_AVAILABLE (~0ULL)
#define APP 4242u
#define OTHER 77u
#define MIB (1024ULL * 1024ULL)

static int is(const char* scenario) {
  const char* asked = getenv("FAKE_NVML");
  return asked != NULL && strcmp(asked, scenario) == 0;
}

// NVML_SUCCESS, or NVML_ERROR_INSUFFICIENT_SIZE with the count when [infos] has no room for [entries]
static int answer(unsigned int* count, ProcessInfo* infos, const ProcessInfo* entries, unsigned int listed) {
  if (listed > 0 && (infos == NULL || *count < listed)) {
    *count = listed;
    return 7;
  }
  if (listed > 0) {
    memcpy(infos, entries, listed * sizeof(ProcessInfo));
  }
  *count = listed;
  return 0;
}

int nvmlInit_v2(void) { return 0; }

int nvmlShutdown(void) { return 0; }

int nvmlDeviceGetCount_v2(unsigned int* count) {
  *count = 1;
  return 0;
}

int nvmlDeviceGetHandleByIndex_v2(unsigned int index, void** device) {
  static int card;
  (void)index;
  *device = &card;
  return 0;
}

int nvmlDeviceGetUUID(void* device, char* uuid, unsigned int length) {
  (void)device;
  strncpy(uuid, "GPU-00112233-4455-6677-8899-aabbccddeeff", length);
  return 0;
}

int nvmlDeviceGetGraphicsRunningProcesses_v3(void* device, unsigned int* count, ProcessInfo* infos) {
  (void)device;
  if (is("measured")) {
    const ProcessInfo entries[] = {{APP, 1402 * MIB, 0, 0}, {OTHER, 512 * MIB, 0, 0}};
    return answer(count, infos, entries, 2);
  }
  if (is("absent")) {
    const ProcessInfo entries[] = {{OTHER, 512 * MIB, 0, 0}};
    return answer(count, infos, entries, 1);
  }
  // "unavailable" and "mixed": the app listed without a figure
  const ProcessInfo entries[] = {{OTHER, 512 * MIB, 0, 0}, {APP, NOT_AVAILABLE, 0, 0}};
  return answer(count, infos, entries, 2);
}

int nvmlDeviceGetComputeRunningProcesses_v3(void* device, unsigned int* count, ProcessInfo* infos) {
  (void)device;
  if (is("mixed")) {
    const ProcessInfo entries[] = {{APP, 300 * MIB, 0, 0}};
    return answer(count, infos, entries, 1);
  }
  return answer(count, infos, NULL, 0);
}
