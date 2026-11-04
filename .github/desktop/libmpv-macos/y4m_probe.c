// y4m_probe: opens one y4m with libmpv, without a window or sound, and prints as JSON what mpv read from it. Built and
// run by check_y4m.py (same folder) against the libmpv frameworks of the macOS build, or the system's libmpv on Linux.
//
//   y4m_probe URL_OR_PATH FORWARD_SECONDS BACK_SECONDS [FORMAT [OPTION=VALUE...]]
//
// FORMAT, when given, is passed as demuxer-lavf-format (no probe), as the app does for the y4m that the AV2 decoder
// serves. The probe waits for the first frame and takes it with screenshot-raw, seeks exactly forward to
// FORWARD_SECONDS, then back to BACK_SECONDS, taking the frame each time, then plays the rest as fast as it decodes
// (untimed) and reads where it stopped. No cache and small reads ahead, so that the seek back goes to the stream (a
// range request over HTTP) rather than to what mpv already holds; a seek forward within the TCP window of the
// connection is read through by FFmpeg instead (its short seek), hence the two. Each OPTION=VALUE after FORMAT is set
// after those, as the app sets its own for an AV2 stream (its cache among them: check_y4m.py companion), and the
// report says how long the first frame took (openSeconds) and the untimed playback (playFrom, playSeconds).
// Exit 0 when it printed a report, even a failed one: check_y4m.py judges it.

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <mpv/client.h>

#define WAIT_SECONDS 20.0

static mpv_handle *mpv;
static char log_text[8192];

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void json_string(const char *text) {
  putchar('"');
  for (const unsigned char *c = (const unsigned char *)(text ? text : ""); *c; c++) {
    if (*c == '"' || *c == '\\') {
      printf("\\%c", *c);
    } else if (*c == '\n') {
      fputs("\\n", stdout);
    } else if (*c < 0x20) {
      printf("\\u%04x", *c);
    } else {
      putchar(*c);
    }
  }
  putchar('"');
}

static void key(const char *name) {
  static int first = 1;
  if (!first) {
    fputs(",\n  ", stdout);
  }
  first = 0;
  json_string(name);
  fputs(": ", stdout);
}

static void put_text(const char *name, const char *value) {
  key(name);
  if (value) {
    json_string(value);
  } else {
    fputs("null", stdout);
  }
}

static void put_property(const char *name) {
  char *value = mpv_get_property_string(mpv, name);
  put_text(name, value);
  mpv_free(value);
}

static void put_number(const char *name, const char *property) {
  double value = 0;
  key(name);
  if (mpv_get_property(mpv, property, MPV_FORMAT_DOUBLE, &value) >= 0) {
    printf("%.6f", value);
  } else {
    fputs("null", stdout);
  }
}

static void keep_log(mpv_event *event) {
  mpv_event_log_message *message = event->data;
  size_t used = strlen(log_text);
  snprintf(log_text + used, sizeof log_text - used, "[%s] %s: %s", message->level, message->prefix, message->text);
}

// Waits for the event [id] (or, with a property name, for that flag to become true). Returns 0 when it came, -1 when
// the file ended first (its error in [error]) or the time ran out
static int wait_for(mpv_event_id id, const char *flag, const char **error) {
  double deadline = now() + WAIT_SECONDS;
  while (now() < deadline) {
    mpv_event *event = mpv_wait_event(mpv, 0.5);
    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      keep_log(event);
    } else if (event->event_id == id && !flag) {
      return 0;
    } else if (flag && event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
      mpv_event_property *property = event->data;
      if (strcmp(property->name, flag) == 0 && property->format == MPV_FORMAT_FLAG && *(int *)property->data) {
        return 0;
      }
    } else if (event->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *end = event->data;
      *error = end->reason == MPV_END_FILE_REASON_ERROR ? mpv_error_string(end->error) : "the file ended";
      return -1;
    }
  }
  *error = "no answer from mpv within 20 seconds";
  return -1;
}

// The mean of the blue, green and red of the 8x8 pixels at the centre of the frame on screen, from screenshot-raw
static void put_frame(const char *name) {
  const char *args[] = {"screenshot-raw", "video", NULL};
  mpv_node result;
  key(name);
  if (mpv_command_ret(mpv, args, &result) < 0) {
    fputs("null", stdout);
    return;
  }
  int64_t w = 0, h = 0, stride = 0;
  const char *format = "";
  mpv_byte_array *data = NULL;
  if (result.format == MPV_FORMAT_NODE_MAP) {
    for (int i = 0; i < result.u.list->num; i++) {
      const char *k = result.u.list->keys[i];
      mpv_node *v = &result.u.list->values[i];
      if (strcmp(k, "w") == 0) w = v->u.int64;
      if (strcmp(k, "h") == 0) h = v->u.int64;
      if (strcmp(k, "stride") == 0) stride = v->u.int64;
      if (strcmp(k, "format") == 0 && v->format == MPV_FORMAT_STRING) format = v->u.string;
      if (strcmp(k, "data") == 0 && v->format == MPV_FORMAT_BYTE_ARRAY) data = v->u.ba;
    }
  }
  if (!data || w < 8 || h < 8 || strcmp(format, "bgr0") != 0 || (size_t)(stride * h) > data->size) {
    fputs("null", stdout);
    mpv_free_node_contents(&result);
    return;
  }
  double sum[3] = {0, 0, 0};
  const unsigned char *pixels = data->data;
  for (int64_t y = h / 2 - 4; y < h / 2 + 4; y++) {
    for (int64_t x = w / 2 - 4; x < w / 2 + 4; x++) {
      const unsigned char *pixel = pixels + y * stride + x * 4;
      for (int c = 0; c < 3; c++) sum[c] += pixel[c];
    }
  }
  printf("{\"w\": %lld, \"h\": %lld, \"bgr\": [%.2f, %.2f, %.2f]}", (long long)w, (long long)h, sum[0] / 64,
         sum[1] / 64, sum[2] / 64);
  mpv_free_node_contents(&result);
}

static int finish(const char *error) {
  put_text("error", error);
  put_text("log", log_text);
  fputs("\n}\n", stdout);
  mpv_terminate_destroy(mpv);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "y4m_probe URL_OR_PATH FORWARD_SECONDS BACK_SECONDS [FORMAT [OPTION=VALUE...]]\n");
    return 2;
  }
  const char *source = argv[1];
  const char *seeks[][2] = {{argv[2], "forward"}, {argv[3], "back"}};
  const char *format = argc > 4 ? argv[4] : NULL;
  const char *error = NULL;

  mpv = mpv_create();
  if (!mpv) {
    fprintf(stderr, "mpv_create failed\n");
    return 2;
  }
  const char *options[][2] = {
      {"config", "no"},     {"terminal", "no"},       {"vo", "null"},          {"ao", "null"},
      {"audio", "no"},      {"keep-open", "yes"},     {"pause", "yes"},        {"cache", "no"},
      {"hr-seek", "yes"},   {"demuxer-readahead-secs", "0.1"}, {"input-default-bindings", "no"},
  };
  for (size_t i = 0; i < sizeof options / sizeof options[0]; i++) {
    if (mpv_set_option_string(mpv, options[i][0], options[i][1]) < 0) {
      fprintf(stderr, "mpv refused the option %s=%s\n", options[i][0], options[i][1]);
      return 2;
    }
  }
  if (format && mpv_set_option_string(mpv, "demuxer-lavf-format", format) < 0) {
    fprintf(stderr, "mpv refused demuxer-lavf-format=%s\n", format);
    return 2;
  }
  for (int i = 5; i < argc; i++) {
    char option[256];
    const char *equals = strchr(argv[i], '=');
    if (!equals || (size_t)(equals - argv[i]) >= sizeof option) {
      fprintf(stderr, "not an OPTION=VALUE: %s\n", argv[i]);
      return 2;
    }
    memcpy(option, argv[i], (size_t)(equals - argv[i]));
    option[equals - argv[i]] = '\0';
    if (mpv_set_option_string(mpv, option, equals + 1) < 0) {
      fprintf(stderr, "mpv refused the option %s\n", argv[i]);
      return 2;
    }
  }
  if (mpv_initialize(mpv) < 0) {
    fprintf(stderr, "mpv_initialize failed\n");
    return 2;
  }
  mpv_request_log_messages(mpv, "warn");
  mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG);

  fputs("{\n  ", stdout);
  put_text("source", source);
  put_text("forcedFormat", format);
  put_property("mpv-version");
  put_property("ffmpeg-version");

  const char *load[] = {"loadfile", source, NULL};
  double opened = now();
  if (mpv_command(mpv, load) < 0) {
    return finish("loadfile refused");
  }
  if (wait_for(MPV_EVENT_FILE_LOADED, NULL, &error) < 0 || wait_for(MPV_EVENT_PLAYBACK_RESTART, NULL, &error) < 0) {
    return finish(error);
  }
  key("openSeconds");
  printf("%.3f", now() - opened);
  put_property("file-format");
  put_property("current-tracks/video/codec");
  put_property("video-params/pixelformat");
  put_property("video-params/w");
  put_property("video-params/h");
  put_number("container-fps", "container-fps");
  put_number("duration", "duration");
  put_property("estimated-frame-count");
  put_number("firstTime", "time-pos");
  put_frame("firstFrame");

  for (size_t i = 0; i < 2; i++) {
    const char *seek_command[] = {"seek", seeks[i][0], "absolute+exact", NULL};
    if (mpv_command(mpv, seek_command) < 0) {
      return finish("seek refused");
    }
    if (wait_for(MPV_EVENT_PLAYBACK_RESTART, NULL, &error) < 0) {
      return finish(error);
    }
    char name[32];
    snprintf(name, sizeof name, "%sTime", seeks[i][1]);
    put_number(name, "time-pos");
    snprintf(name, sizeof name, "%sFrame", seeks[i][1]);
    put_frame(name);
  }

  put_number("playFrom", "time-pos");
  mpv_set_property_string(mpv, "untimed", "yes");
  mpv_set_property_string(mpv, "pause", "no");
  double played = now();
  if (wait_for(MPV_EVENT_NONE, "eof-reached", &error) < 0) {
    return finish(error);
  }
  key("playSeconds");
  printf("%.3f", now() - played);
  put_number("endTime", "time-pos");
  put_property("frame-drop-count");
  put_property("decoder-frame-drop-count");
  return finish(NULL);
}
