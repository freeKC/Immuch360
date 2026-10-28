#include "gpu_probe.h"
#include "my_application.h"

int main(int argc, char** argv) {
  // A start of the app by itself to read the graphics cards
  // (lib/desktop/ai/gpu/gpu_probe.dart): it writes their JSON and ends here,
  // before the application and any window
  const char* gpu_probe_output = GpuProbeOutput(argc, argv);
  if (gpu_probe_output != nullptr) {
    return RunGpuProbe(gpu_probe_output);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
