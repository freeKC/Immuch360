#ifndef RUNNER_LAUNCH_HINTS_H_
#define RUNNER_LAUNCH_HINTS_H_

// What the app sets in its environment at launch, before GTK and any thread
// start (lib/desktop/platform/linux_launch_hints.dart, parity lot L11 of
// release 51): WEBKIT_DISABLE_DMABUF_RENDERER=1 on a computer where the NVIDIA
// driver runs, unless the user set the variable already or turned the setting
// "Splats on an NVIDIA card" of This computer off (desktop_linux.json of the
// app's support folder). setenv is not safe once other threads may read the
// environment, so it is done here, first thing in main.
void ApplyLaunchHints();

// Whether the text of desktop_linux.json keeps the DMABUF renderer of WebKitGTK
// on: "webkitDmabufOff": false. Anything else, a missing or damaged file
// included, turns it off (the default of the setting).
bool DmabufOffInSettings(const char* json);

#endif  // RUNNER_LAUNCH_HINTS_H_
