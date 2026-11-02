// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-av2: plays AV2 videos in Immuch360 Desktop. The app reads the container (IVF or OBUs) and feeds the
// temporal units through the standard input; this program decodes them with the library of dav2d (VideoLAN) and
// serves the pictures to the player of the app (libmpv) as a virtual y4m over HTTP on 127.0.0.1, so that no decoded
// byte crosses the app (plan of the 2nd of November 2026, section 2). The arguments, records and lines are those of
// README.md next to the sources; the text of --help is frozen in mobile/test/fixtures/av2/immuch360_av2_help.txt.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dav2d/dav2d.h>

#include "av2.h"
#include "platform.h"

static const char help[] =
    "immuch360-av2: plays AV2 videos in Immuch360 Desktop, decoded by dav2d and served to the player as a y4m on\n"
    "127.0.0.1\n"
    "\n"
    "Usage:\n"
    "  immuch360-av2 probe FILE|- [--threads N]\n"
    "      what the start of an AV2 file holds (IVF or OBUs, - for the standard input), as one line of JSON\n"
    "  immuch360-av2 serve --token TOKEN --width W --height H --bits 8|10 --fps NUM/DEN --frames N [options]\n"
    "      decodes the temporal units of the standard input and serves the pictures as a virtual y4m at\n"
    "      http://127.0.0.1:PORT/TOKEN/video.y4m, until the standard input closes\n"
    "  immuch360-av2 --version\n"
    "  immuch360-av2 --help\n"
    "\n"
    "Options of serve:\n"
    "  --token TOKEN          16 to 128 letters, digits, - or _: the first part of the path of the video\n"
    "  --width W --height H   the size of the pictures, as the probe found it\n"
    "  --bits 8|10            the depth of the pictures\n"
    "  --fps NUM/DEN          the frame rate the y4m header gives the player\n"
    "  --frames N             the number of pictures, one per temporal unit\n"
    "  --threads N            threads of the decoder, 0 for every logical processor (default 0)\n"
    "  --range limited|full   the colour range the y4m header gives the player (default limited)\n"
    "  --depth 8              serves 10-bit pictures as 8-bit samples\n"
    "  --frame-bytes B        stops unless a picture takes B bytes in the y4m\n"
    "  --port P               the port to listen on (default 0, any free port)\n"
    "\n"
    "Standard input of serve: records of a 16-byte header, little endian (\"AV2R\", generation, unit, length), then\n"
    "length bytes. First the index: generation 0, unit 4294967295, the random access units as 32-bit numbers.\n"
    "Then, for each line \"need G U\", the temporal units from U on with generation G, and a record of length 0\n"
    "after the last unit.\n"
    "Standard output of serve: listening PORT, need G U, request, stat, refused, error and exit lines.\n"
    "Exit codes: 0 the standard input closed, 1 internal error, 2 bad arguments, 3 the video cannot be decoded,\n"
    "4 no socket on 127.0.0.1, 5 records that are not the protocol's.\n";

static int usage(const char *problem) {
  fprintf(stderr, "immuch360-av2: %s (see immuch360-av2 --help)\n", problem);
  return AV2_EXIT_USAGE;
}

static int number(const char *text, uint64_t max, uint64_t *value) {
  char *end = NULL;
  if (!text || !*text || *text == '-') return 0;
  unsigned long long parsed = strtoull(text, &end, 10);
  if (*end != '\0' || parsed > max) return 0;
  *value = parsed;
  return 1;
}

static int token_ok(const char *token) {
  size_t length = strlen(token);
  if (length < 16 || length > 128) return 0;
  for (size_t i = 0; i < length; i++) {
    char c = token[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'))
      return 0;
  }
  return 1;
}

static int version(void) {
  av2_line("immuch360-av2 protocol %d, source %s", AV2_PROTOCOL, AV2_SOURCE_COMMIT);
  av2_line("dav2d %s (%s)", AV2_DAV2D_COMMIT, dav2d_version());
  av2_line("simd %s, uses %s", av2_simd_all(), av2_simd_level());
  return AV2_EXIT_OK;
}

static int serve(int argc, char **argv) {
  ServeOptions o;
  memset(&o, 0, sizeof(o));
  int have_width = 0, have_height = 0, have_bits = 0, have_fps = 0, have_frames = 0;
  for (int i = 2; i < argc; i += 2) {
    const char *name = argv[i], *value = i + 1 < argc ? argv[i + 1] : NULL;
    uint64_t n = 0;
    if (!value) return usage("an option without its value");
    if (strcmp(name, "--token") == 0) {
      if (!token_ok(value)) return usage("--token takes 16 to 128 letters, digits, - or _");
      o.token = value;
    } else if (strcmp(name, "--width") == 0) {
      if (!number(value, 65536, &n) || n == 0) return usage("--width takes a number from 1 to 65536");
      o.width = (unsigned)n, have_width = 1;
    } else if (strcmp(name, "--height") == 0) {
      if (!number(value, 65536, &n) || n == 0) return usage("--height takes a number from 1 to 65536");
      o.height = (unsigned)n, have_height = 1;
    } else if (strcmp(name, "--bits") == 0) {
      if (!number(value, 10, &n) || (n != 8 && n != 10)) return usage("--bits takes 8 or 10");
      o.bits = (unsigned)n, have_bits = 1;
    } else if (strcmp(name, "--depth") == 0) {
      if (!number(value, 8, &n) || n != 8) return usage("--depth takes 8");
      o.depth = 8;
    } else if (strcmp(name, "--fps") == 0) {
      const char *slash = strchr(value, '/');
      char numerator[24];
      uint64_t den = 0;
      if (!slash || (size_t)(slash - value) >= sizeof(numerator)) return usage("--fps takes NUM/DEN");
      memcpy(numerator, value, (size_t)(slash - value));
      numerator[slash - value] = '\0';
      if (!number(numerator, 0xffffffffu, &n) || !number(slash + 1, 0xffffffffu, &den) || n == 0 || den == 0)
        return usage("--fps takes NUM/DEN, two numbers above 0");
      o.fps_num = (unsigned)n, o.fps_den = (unsigned)den, have_fps = 1;
    } else if (strcmp(name, "--frames") == 0) {
      if (!number(value, 100000000u, &n) || n == 0) return usage("--frames takes a number from 1 to 100000000");
      o.frames = n, have_frames = 1;
    } else if (strcmp(name, "--threads") == 0) {
      if (!number(value, 256, &n)) return usage("--threads takes a number from 0 to 256");
      o.threads = (int)n;
    } else if (strcmp(name, "--range") == 0) {
      if (strcmp(value, "limited") != 0 && strcmp(value, "full") != 0) return usage("--range takes limited or full");
      o.full_range = strcmp(value, "full") == 0;
    } else if (strcmp(name, "--frame-bytes") == 0) {
      if (!number(value, UINT64_MAX, &n) || n == 0) return usage("--frame-bytes takes a number above 0");
      o.frame_bytes = n;
    } else if (strcmp(name, "--port") == 0) {
      if (!number(value, 65535, &n)) return usage("--port takes a number from 0 to 65535");
      o.port = (unsigned)n;
    } else {
      return usage("an unknown option of serve");
    }
  }
  if (!o.token || !have_width || !have_height || !have_bits || !have_fps || !have_frames)
    return usage("serve needs --token, --width, --height, --bits, --fps and --frames");
  return av2_serve(&o);
}

int main(int argc, char **argv) {
  av2_platform_init();
  if (argc == 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
    fputs(help, stdout);
    fflush(stdout);
    return AV2_EXIT_OK;
  }
  if (argc == 2 && strcmp(argv[1], "--version") == 0) return version();
  if (argc >= 3 && strcmp(argv[1], "probe") == 0) {
    uint64_t threads = 0;
    if (argc == 5 && strcmp(argv[3], "--threads") == 0) {
      if (!number(argv[4], 256, &threads)) return usage("--threads takes a number from 0 to 256");
    } else if (argc != 3) {
      return usage("probe takes a file, or - for the standard input, and --threads N");
    }
    return av2_probe(argv[2], 2, (int)threads);
  }
  if (argc >= 2 && strcmp(argv[1], "serve") == 0) return serve(argc, argv);
  fputs(help, stderr);
  return AV2_EXIT_USAGE;
}
