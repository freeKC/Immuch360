#include "launch_hints.h"

#include <glib.h>

#include <cctype>
#include <cstdlib>
#include <cstring>

namespace {

constexpr char kDmabufVariable[] = "WEBKIT_DISABLE_DMABUF_RENDERER";
constexpr char kSettingsFile[] = "desktop_linux.json";
constexpr char kDmabufKey[] = "\"webkitDmabufOff\"";

// The support folder of the app as path_provider_linux finds it: the data
// folder of the user, then the application id, or the name of the executable
// when only that older folder exists
gchar* SupportFolder() {
  const gchar* data = g_get_user_data_dir();
  gchar* by_id = g_build_filename(data, APPLICATION_ID, nullptr);
  if (g_file_test(by_id, G_FILE_TEST_IS_DIR)) {
    return by_id;
  }
  gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe != nullptr) {
    gchar* name = g_path_get_basename(exe);
    gchar* dot = strrchr(name, '.');
    if (dot != nullptr && dot != name) {
      *dot = '\0';
    }
    gchar* legacy = g_build_filename(data, name, nullptr);
    g_free(name);
    g_free(exe);
    if (g_file_test(legacy, G_FILE_TEST_IS_DIR)) {
      g_free(by_id);
      return legacy;
    }
    g_free(legacy);
  }
  return by_id;
}

}  // namespace

bool DmabufOffInSettings(const char* json) {
  if (json == nullptr) {
    return true;
  }
  const char* key = strstr(json, kDmabufKey);
  if (key == nullptr) {
    return true;
  }
  const char* value = key + strlen(kDmabufKey);
  while (*value != '\0' && isspace(static_cast<unsigned char>(*value))) {
    value++;
  }
  if (*value != ':') {
    return true;
  }
  value++;
  while (*value != '\0' && isspace(static_cast<unsigned char>(*value))) {
    value++;
  }
  return strncmp(value, "false", 5) != 0;
}

void ApplyLaunchHints() {
  if (getenv(kDmabufVariable) != nullptr ||
      !g_file_test("/proc/driver/nvidia/version", G_FILE_TEST_EXISTS)) {
    return;
  }
  gchar* folder = SupportFolder();
  gchar* path = g_build_filename(folder, kSettingsFile, nullptr);
  gchar* json = nullptr;
  if (!g_file_get_contents(path, &json, nullptr, nullptr)) {
    json = nullptr;
  }
  if (DmabufOffInSettings(json)) {
    setenv(kDmabufVariable, "1", 0);
  }
  g_free(json);
  g_free(path);
  g_free(folder);
}
