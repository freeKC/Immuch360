// gpu_probe_nvml_test.dart builds this with the Linux probe itself (linux/runner/gpu_probe.cc, its anonymous namespace
// included) and runs it with fake_nvml.c as libnvidia-ml.so.1: what the probe writes of the share of the process 4242
// on the one NVIDIA card, "app <bytes>" or "app unknown".

#include "gpu_probe.cc"

int main() {
  Report report;
  Adapter card;
  card.name = "NVIDIA GeForce RTX 2060";
  card.vendor_id = 0x10DE;
  card.uuid = "00112233445566778899aabbccddeeff";
  report.adapters.push_back(card);
  ReadAppMemory(&report, 4242);
  const Adapter& read = report.adapters.front();
  if (read.has_app_memory) {
    std::printf("app %llu\n", static_cast<unsigned long long>(read.app_memory));
  } else {
    std::printf("app unknown\n");
  }
  return 0;
}
