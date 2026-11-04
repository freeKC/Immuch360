// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// The bytes around the decoder: the OBUs of AV2 (a LEB128 size that counts the header, then a header byte whose bits
// 2 to 6 are the type), the IVF and Section 5 containers the probe reads, and the virtual y4m serve writes.
#ifndef IMMUCH360_AV2_STREAM_H
#define IMMUCH360_AV2_STREAM_H

#include <stddef.h>
#include <stdint.h>

enum {
  OBU_SEQUENCE_HEADER = 1,
  OBU_TEMPORAL_DELIMITER = 2,
  OBU_CLOSED_LOOP_KEY = 4,
  OBU_OPEN_LOOP_KEY = 5,
  OBU_RAS_FRAME = 21,
  OBU_CONTENT_INTERPRETATION = 24,
};

// One OBU at data: its total length (size field included), its type and where its payload starts (after the size
// field and the header bytes); 0 when the bytes do not hold a whole one
int obu_at(const uint8_t *data, size_t size, size_t *length, int *type, size_t *payload);

// --- the virtual y4m -------------------------------------------------------------------------------------------------

typedef struct Y4mLayout {
  unsigned width, height;
  unsigned bits;          // of the samples served: 8, or 10 in 16 bit little endian words
  unsigned fps_num, fps_den;
  int full_range;
  uint64_t frames;
  char header[160];
  size_t header_length;
  size_t frame_bytes;     // the samples of one picture, 4:2:0
  size_t record_bytes;    // "FRAME\n" and the samples
  uint64_t total;         // the header and every record
} Y4mLayout;

// Fills the header and the sizes; 0 when the numbers cannot make a y4m
int y4m_layout(Y4mLayout *layout, unsigned width, unsigned height, unsigned bits, unsigned fps_num, unsigned fps_den,
               int full_range, uint64_t frames);

// --- the input of the probe ------------------------------------------------------------------------------------------

typedef struct Container {
  int ivf;                // 1 IVF, 0 Section 5 (a plain row of OBUs)
  char fourcc[5];
  unsigned ivf_width, ivf_height, ivf_rate, ivf_scale, ivf_frames;
  const uint8_t *data;
  size_t size, at;
} Container;

// Recognises the container of the first bytes; 0 with *reason set when it is neither an AV2 IVF nor AV2 OBUs
int container_open(Container *c, const uint8_t *data, size_t size, const char **reason);
// The next packet to feed the decoder (an IVF frame, or one temporal unit of OBUs); 0 at the end of the bytes
int container_next(Container *c, const uint8_t **packet, size_t *length);

#endif
