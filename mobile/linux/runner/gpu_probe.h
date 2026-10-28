#ifndef RUNNER_GPU_PROBE_H_
#define RUNNER_GPU_PROBE_H_

// What the graphics cards of this computer offer, for the 360° panoramas of
// the AI features (design-final 2026-10-27, section 4.7). The app starts its
// own executable again with --immuch360-gpu-probe=<file>
// (lib/desktop/ai/gpu/gpu_probe.dart); main.cc hands that start here before
// the application is made, so before any window. A driver that
// crashes or hangs in the probe takes down this child, never the app.

// The file the command line names after --immuch360-gpu-probe=, null when
// it does not ask for the probe
const char* GpuProbeOutput(int argc, char** argv);

// Writes the JSON of the cards to [output] and gives the exit code of the
// process: 0 once the JSON is written, whatever it found
int RunGpuProbe(const char* output);

#endif  // RUNNER_GPU_PROBE_H_
