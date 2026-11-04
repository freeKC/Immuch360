// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
#include "stream.h"

#include <stdio.h>
#include <string.h>

static int leb128(const uint8_t *data, size_t size, uint64_t *value, size_t *used) {
  uint64_t result = 0;
  for (size_t i = 0; i < 8 && i < size; i++) {
    result |= (uint64_t)(data[i] & 0x7f) << (7 * i);
    if (!(data[i] & 0x80)) {
      *value = result;
      *used = i + 1;
      return 1;
    }
  }
  return 0;
}

int obu_at(const uint8_t *data, size_t size, size_t *length, int *type, size_t *payload) {
  uint64_t obu_size;
  size_t used;
  if (!leb128(data, size, &obu_size, &used) || obu_size < 1 || obu_size > size - used) return 0;
  int extension = data[used] >> 7;
  if (obu_size < 1u + (unsigned)extension) return 0;
  *type = (data[used] >> 2) & 0x1f;
  *length = used + (size_t)obu_size;
  *payload = used + 1 + (size_t)extension;
  return 1;
}

int y4m_layout(Y4mLayout *layout, unsigned width, unsigned height, unsigned bits, unsigned fps_num, unsigned fps_den,
               int full_range, uint64_t frames) {
  memset(layout, 0, sizeof(*layout));
  if (width == 0 || height == 0 || width > 65536 || height > 65536 || (bits != 8 && bits != 10) || fps_num == 0 ||
      fps_den == 0 || frames == 0 || frames > 100000000u)
    return 0;
  layout->width = width;
  layout->height = height;
  layout->bits = bits;
  layout->fps_num = fps_num;
  layout->fps_den = fps_den;
  layout->full_range = full_range;
  layout->frames = frames;
  // The colour space names of the y4m writer of dav2d: C420 in 8 bits, C420p10 in 10 bits (16 bit samples)
  int written = snprintf(layout->header, sizeof(layout->header),
                         "YUV4MPEG2 W%u H%u F%u:%u Ip A1:1 C%s XCOLORRANGE=%s\n", width, height, fps_num, fps_den,
                         bits == 8 ? "420" : "420p10", full_range ? "FULL" : "LIMITED");
  if (written <= 0 || (size_t)written >= sizeof(layout->header)) return 0;
  layout->header_length = (size_t)written;
  size_t chroma = (size_t)((width + 1) / 2) * ((height + 1) / 2);
  layout->frame_bytes = ((size_t)width * height + 2 * chroma) * (bits == 8 ? 1 : 2);
  layout->record_bytes = 6 + layout->frame_bytes;
  layout->total = layout->header_length + frames * (uint64_t)layout->record_bytes;
  return 1;
}

static unsigned le16(const uint8_t *p) { return (unsigned)p[0] | (unsigned)p[1] << 8; }
static unsigned le32(const uint8_t *p) { return le16(p) | (unsigned)le16(p + 2) << 16; }

int container_open(Container *c, const uint8_t *data, size_t size, const char **reason) {
  memset(c, 0, sizeof(*c));
  c->data = data;
  c->size = size;
  if (size >= 32 && memcmp(data, "DKIF", 4) == 0) {
    memcpy(c->fourcc, data + 8, 4);
    for (int i = 0; i < 4; i++) {
      if (c->fourcc[i] < 0x20 || c->fourcc[i] > 0x7e) c->fourcc[i] = '?';
    }
    if (memcmp(data + 8, "AV02", 4) != 0) {
      *reason = memcmp(data + 8, "AV01", 4) == 0 ? "an IVF of AV1, not AV2" : "an IVF of another codec";
      return 0;
    }
    unsigned header = le16(data + 6);
    if (header < 32 || header > size) {
      *reason = "an IVF header of a wrong length";
      return 0;
    }
    c->ivf = 1;
    c->ivf_width = le16(data + 12);
    c->ivf_height = le16(data + 14);
    c->ivf_rate = le32(data + 16);
    c->ivf_scale = le32(data + 20);
    c->ivf_frames = le32(data + 24);
    c->at = header;
    return 1;
  }
  // Section 5: a temporal delimiter first, as the probe of dav2d asks
  size_t length, payload;
  int type;
  if (obu_at(data, size, &length, &type, &payload) && type == OBU_TEMPORAL_DELIMITER) {
    memcpy(c->fourcc, "OBU", 4);
    return 1;
  }
  *reason = "neither an AV2 IVF nor AV2 OBUs";
  return 0;
}

int container_next(Container *c, const uint8_t **packet, size_t *length) {
  if (c->ivf) {
    if (c->size - c->at < 12) return 0;
    size_t frame = le32(c->data + c->at);
    if (frame > c->size - c->at - 12) return 0;
    *packet = c->data + c->at + 12;
    *length = frame;
    c->at += 12 + frame;
    return frame > 0 ? 1 : container_next(c, packet, length);
  }
  // One temporal unit: from a delimiter to the next one
  size_t start = c->at, at = c->at;
  while (at < c->size) {
    size_t obu, payload;
    int type;
    if (!obu_at(c->data + at, c->size - at, &obu, &type, &payload)) break;
    if (type == OBU_TEMPORAL_DELIMITER && at > start) break;
    at += obu;
  }
  if (at == start) return 0;
  *packet = c->data + start;
  *length = at - start;
  c->at = at;
  return 1;
}
