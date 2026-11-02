// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-av2 probe FILE|-: what the app needs to know before serve, as one line of JSON. The sequence header comes
// from dav2d_parse_sequence_header; the size, depth and colour of the pictures from decoding the first one (the
// colour description of AV2 is in its own OBU, which only the decoder reads). The app reads the frame rate and the
// number of pictures from the container itself, and refuses what this version does not play with the "format" text.
#include "av2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dav2d/dav2d.h>

#include "platform.h"
#include "stream.h"

#ifdef _WIN32
#include <shellapi.h>
#endif

// The probe reads the start of a file: the first pictures of any AV2 stream are well inside
#define PROBE_LIMIT ((size_t)64 << 20)
#define PROBE_PACKETS 64

static uint8_t *read_input(const char *path, int index, size_t *size) {
  FILE *file = NULL;
  if (strcmp(path, "-") == 0) {
    file = stdin;
  } else {
#ifdef _WIN32
    // The path as the app gave it, in UTF-16: argv of the C runtime is in the code page and loses other letters
    int count = 0;
    wchar_t **wide = CommandLineToArgvW(GetCommandLineW(), &count);
    if (wide && index < count) file = _wfopen(wide[index], L"rb");
    if (wide) LocalFree(wide);
#else
    (void)index;
    file = fopen(path, "rb");
#endif
  }
  if (!file) return NULL;
  size_t capacity = 1 << 20, used = 0;
  uint8_t *data = malloc(capacity);
  while (data) {
    if (used == capacity) {
      if (capacity >= PROBE_LIMIT) break;
      uint8_t *grown = realloc(data, capacity * 2);
      if (!grown) {
        free(data);
        data = NULL;
        break;
      }
      data = grown;
      capacity *= 2;
    }
    size_t room = capacity - used;
    size_t got = file == stdin ? av2_stdin_read(data + used, room) : fread(data + used, 1, room, file);
    if (got == 0) break;
    used += got;
  }
  if (file != stdin) fclose(file);
  *size = used;
  return data;
}

static const char *layout_name(int layout) {
  switch (layout) {
    case DAV2D_PIXEL_LAYOUT_I400: return "400";
    case DAV2D_PIXEL_LAYOUT_I420: return "420";
    case DAV2D_PIXEL_LAYOUT_I422: return "422";
    default: return "444";
  }
}

static const char *layout_words(int layout) {
  switch (layout) {
    case DAV2D_PIXEL_LAYOUT_I400: return "monochrome";
    case DAV2D_PIXEL_LAYOUT_I420: return "4:2:0";
    case DAV2D_PIXEL_LAYOUT_I422: return "4:2:2";
    default: return "4:4:4";
  }
}

// The colour triplet a description type of AV2 stands for (Dav2dColorDescription)
static void described_colour(const Dav2dContentInterpretation *ci, unsigned *pri, unsigned *trc, unsigned *mtrx) {
  *pri = DAV2D_COLOR_PRI_UNKNOWN;
  *trc = DAV2D_TRC_UNKNOWN;
  *mtrx = DAV2D_MC_UNKNOWN;
  if (!ci || !ci->color_description_present) return;
  switch (ci->color.type) {
    case DAV2D_COLOR_DESC_BT709SDR: *pri = 1, *trc = 1, *mtrx = 1; break;
    case DAV2D_COLOR_DESC_BT2100PQ: *pri = 9, *trc = 16, *mtrx = 9; break;
    case DAV2D_COLOR_DESC_BT2100HLG: *pri = 9, *trc = 18, *mtrx = 9; break;
    case DAV2D_COLOR_DESC_SRGB: *pri = 1, *trc = 13, *mtrx = 0; break;
    case DAV2D_COLOR_DESC_SRGBSYCC: *pri = 1, *trc = 13, *mtrx = 5; break;
    default: *pri = ci->color.pri, *trc = ci->color.trc, *mtrx = ci->color.mtrx; break;
  }
}

// The sequence header of an AV2 packet, read by dav2d. dav2d_parse_sequence_header of dav2d at the commit of the lock
// still reads the OBU header of AV1 (forbidden bit, four bits of type, then the size), so the payload of the AV2
// sequence header OBU is handed to it behind such a header: the parser of the header itself is the one the decoder
// uses (parse_seq_hdr)
static int parse_sequence(const uint8_t *packet, size_t length, Dav2dSequenceHeader *out) {
  size_t at = 0;
  while (at < length) {
    size_t obu, payload;
    int type;
    if (!obu_at(packet + at, length - at, &obu, &type, &payload)) return 0;
    if (type == OBU_SEQUENCE_HEADER) {
      size_t size = obu - payload;
      uint8_t *wrapped = malloc(size + 10);
      if (!wrapped) return 0;
      size_t used = 0;
      wrapped[used++] = 0x0a;  // AV1: type 1 (sequence header), a size field
      size_t rest = size;
      do {
        uint8_t byte = rest & 0x7f;
        rest >>= 7;
        wrapped[used++] = (uint8_t)(byte | (rest ? 0x80 : 0));
      } while (rest);
      memcpy(wrapped + used, packet + at + payload, size);
      int parsed = dav2d_parse_sequence_header(out, wrapped, used + size) == 0;
      free(wrapped);
      return parsed;
    }
    at += obu;
  }
  return 0;
}

static int fail(const char *reason) {
  av2_line("{\"error\":\"%s\"}", reason);
  return AV2_EXIT_VIDEO;
}

int av2_probe(const char *path, int path_index, int threads) {
  size_t size = 0;
  uint8_t *data = read_input(path, path_index, &size);
  if (!data) return fail("the file could not be read");
  Container container;
  const char *reason = NULL;
  if (!container_open(&container, data, size, &reason)) {
    free(data);
    return fail(reason);
  }

  Dav2dSequenceHeader sequence;
  int have_sequence = 0;
  Dav2dSettings settings;
  dav2d_default_settings(&settings);
  settings.n_threads = threads;
  settings.max_frame_delay = 1;
  settings.all_layers = 0;
  settings.logger.callback = NULL;
  Dav2dContext *decoder = NULL;
  if (dav2d_open(&decoder, &settings) < 0) {
    free(data);
    return fail("the decoder could not start");
  }
  Dav2dPicture picture;
  memset(&picture, 0, sizeof(picture));
  int have_picture = 0, decode_error = 0;
  const uint8_t *packet;
  size_t length;
  for (int packets = 0; !have_picture && packets < PROBE_PACKETS && container_next(&container, &packet, &length);
       packets++) {
    if (!have_sequence) have_sequence = parse_sequence(packet, length, &sequence);
    Dav2dData input;
    memset(&input, 0, sizeof(input));
    uint8_t *copy = dav2d_data_create(&input, length);
    if (!copy) break;
    memcpy(copy, packet, length);
    // The loop of the documentation of dav2d_get_picture: send until the data is taken, take every picture out
    do {
      if (input.sz > 0) {
        int sent = dav2d_send_data(decoder, &input);
        if (sent < 0 && sent != DAV2D_ERR(EAGAIN)) {
          decode_error = 1;
          break;
        }
      }
      int got = dav2d_get_picture(decoder, &picture);
      if (got == 0) {
        have_picture = 1;
      } else if (got != DAV2D_ERR(EAGAIN)) {
        decode_error = 1;
      }
    } while (input.sz > 0 && !have_picture && !decode_error);
    if (input.sz > 0) dav2d_data_unref(&input);
    if (decode_error) break;
  }
  if (!have_picture && !decode_error) {
    dav2d_send_data(decoder, NULL);
    if (dav2d_get_picture(decoder, &picture) == 0) have_picture = 1;
  }

  if (!have_sequence) {
    if (have_picture) dav2d_picture_unref(&picture);
    dav2d_close(&decoder);
    free(data);
    return fail("no AV2 sequence header in the start of the file");
  }

  unsigned bits = sequence.hbd == 0 ? 8 : sequence.hbd == 1 ? 10 : 12;
  int layout = sequence.layout;
  if (have_picture) {
    bits = (unsigned)picture.p.bpc;
    layout = picture.p.layout;
  }
  char format[64];
  snprintf(format, sizeof(format), "%s %u-bit", layout_words(layout), bits);
  const char *refusal = NULL;
  if (layout != DAV2D_PIXEL_LAYOUT_I420) {
    refusal = format;
  } else if (bits != 8 && bits != 10) {
    refusal = format;
  } else if (!have_picture) {
    refusal = decode_error ? "a stream the decoder stops on" : "a stream without a picture in its start";
  }
  unsigned pri, trc, mtrx;
  const Dav2dContentInterpretation *ci = have_picture ? picture.ci : NULL;
  described_colour(ci, &pri, &trc, &mtrx);
  int full_range = ci && ci->color_description_present && ci->color.range;
  Y4mLayout y4m;
  int y4m_ok = have_picture &&
               y4m_layout(&y4m, (unsigned)picture.p.w, (unsigned)picture.p.h, bits, 1, 1, full_range, 1);

  char ivf[160] = "null";
  if (container.ivf) {
    snprintf(ivf, sizeof(ivf), "{\"width\":%u,\"height\":%u,\"rate\":%u,\"scale\":%u,\"frames\":%u}",
             container.ivf_width, container.ivf_height, container.ivf_rate, container.ivf_scale, container.ivf_frames);
  }
  char shown[160] = "null";
  if (have_picture) {
    snprintf(shown, sizeof(shown), "{\"width\":%d,\"height\":%d,\"bits\":%d,\"layout\":\"%s\"}", picture.p.w,
             picture.p.h, picture.p.bpc, layout_name(picture.p.layout));
  }
  char served[96] = "null";
  if (y4m_ok) {
    snprintf(served, sizeof(served), "{\"colorspace\":\"%s\",\"frame_bytes\":%zu}", bits == 8 ? "420" : "420p10",
             y4m.frame_bytes);
  }
  av2_line("{\"container\":\"%s\",\"fourcc\":\"%s\",\"ivf\":%s,"
           "\"sequence\":{\"profile\":%u,\"level\":%u,\"tier\":%u,\"bits\":%u,\"layout\":\"%s\",\"max_width\":%d,"
           "\"max_height\":%d,\"still_picture\":%s,\"temporal_layers\":%u,\"embedded_layers\":%u,\"film_grain\":%s},"
           "\"picture\":%s,\"color\":{\"description\":%s,\"primaries\":%u,\"transfer\":%u,\"matrix\":%u,"
           "\"range\":\"%s\"},\"format\":\"%s\",\"playable\":%s,\"refusal\":%s%s%s,\"y4m\":%s}",
           container.ivf ? "ivf" : "obu", container.fourcc, ivf, sequence.profile, sequence.level, sequence.tier,
           sequence.hbd == 0 ? 8u : sequence.hbd == 1 ? 10u : 12u, layout_name(sequence.layout), sequence.max_width,
           sequence.max_height, sequence.still_picture ? "true" : "false", (unsigned)sequence.max_tlayer_id + 1,
           (unsigned)sequence.max_mlayer_id + 1, sequence.film_grain_present ? "true" : "false", shown,
           ci && ci->color_description_present ? "true" : "false", pri, trc, mtrx, full_range ? "full" : "limited",
           format, refusal ? "false" : "true", refusal ? "\"" : "", refusal ? refusal : "null", refusal ? "\"" : "",
           served);

  if (have_picture) dav2d_picture_unref(&picture);
  dav2d_close(&decoder);
  free(data);
  return AV2_EXIT_OK;
}
