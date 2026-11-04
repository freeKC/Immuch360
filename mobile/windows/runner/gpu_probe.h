#ifndef RUNNER_GPU_PROBE_H_
#define RUNNER_GPU_PROBE_H_

#include <string>

// What the graphics cards of this computer offer, for the 360° panoramas of
// the AI features (design-final 2026-10-27, section 4.7). The app starts its
// own executable again with --immuch360-gpu-probe=<file>
// (lib/desktop/ai/gpu/gpu_probe.dart); main.cpp hands that start here before
// the guard of the single instance and before any window. A driver that
// crashes or hangs in the probe takes down this child, never the app.

// Whether the command line asks for the probe, and the file it names
bool GpuProbeRequested(std::wstring* output);

// The id of the app's process after --immuch360-gpu-probe-pid=, whose share
// of each card the probe reads; 0 when not given
unsigned long GpuProbePid();

// Writes the JSON of the cards to [output], with what the process [pid] holds
// of each card when it can be read (0: nothing read), and gives the exit code
// of the process: 0 once the JSON is written, whatever it found
int RunGpuProbe(const std::wstring& output, unsigned long pid);

#endif  // RUNNER_GPU_PROBE_H_
