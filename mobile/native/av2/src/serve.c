// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-av2 serve: one decoder, one connection at a time. Four threads:
//
//  - the main thread answers the requests of the player: a byte range of the virtual y4m maps to the picture k and an
//    offset in it; the decoder goes on from where it is when the random access point before k is not after it, and
//    otherwise starts again there (a new generation, "need G U" for the app); the pictures before k are dropped
//    unwritten, then each picture is written whole to the socket. A paused player stops reading, the write blocks,
//    the decoder and the app wait: no processor time is spent;
//  - the input thread reads the records of the app into a short queue, skips those of an older generation, and ends
//    the program when the standard input closes;
//  - the accept thread reads each new request, refuses another token or address, and hands it to the main thread;
//    a new request replaces the one being served (its socket is shut down), as the player does when it seeks;
//  - the report thread writes the "stat" line every half second.
//
// The decoding speed of the stat line is measured on the main thread over runs of pictures where nothing but the
// decoder held it: neither a player that does not read (a write that has to wait) nor the app (a unit that has not
// come). The first pictures of a run are left out, the decoder threads having worked ahead while the main thread
// waited. A run happens when playback starts, after a seek, and all the time when the computer is too slow: the number
// says what this computer decodes, not the frame rate of the video.
#include "av2.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dav2d/dav2d.h>

#include "platform.h"
#include "stream.h"

#define RECORD_MAGIC 0x52325641u  // "AV2R" in little endian
#define INDEX_UNIT 0xffffffffu
#define RECORD_LIMIT ((uint32_t)256 << 20)
#define QUEUE_RECORDS 64
#define QUEUE_BYTES ((size_t)32 << 20)
#define REQUEST_LIMIT 16384

typedef struct Record {
  struct Record *next;
  uint32_t generation, unit, length;
  uint8_t *data;
} Record;

typedef struct Request {
  av2_socket socket;
  uint64_t start, end;  // the bytes asked, end included
  int ranged;
} Request;

typedef struct Server {
  Y4mLayout y4m;
  const ServeOptions *options;
  char path[160];
  av2_socket listener;

  av2_mutex lock;
  av2_cond wake;  // a record came, a request came, room was made in the queue, the index came

  Record *head, *tail;
  size_t queued_records, queued_bytes;
  uint32_t generation;
  uint32_t *raps;
  size_t rap_count;

  int has_pending;
  Request pending;
  av2_socket serving;

  uint64_t decoded, served;
  int64_t position;
  double fps;  // the last decoding speed measured, 0 before the first
} Server;

// A run of pictures the decoder alone paced (main thread only)
typedef struct Run {
  unsigned pictures;   // since the start of the run
  unsigned skip;       // the first pictures, left out: the decoder threads worked ahead of them
  uint64_t first_ns;   // when picture `skip` came
  uint64_t last_ns;    // when the last picture came
} Run;

typedef struct Decoder {
  Server *server;
  Dav2dContext *context;
  Run run;
  Dav2dData data;       // taken from the queue, not yet taken by dav2d
  int started, draining, ended;
  uint32_t expected;    // the unit the next record must carry
  int64_t next;         // the picture the decoder gives next
  int64_t frame_index;  // the picture in frame, -1 when none
  uint8_t *frame;       // "FRAME\n" and the samples of the picture frame_index
} Decoder;

static Server server;

static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void stop(int code, const char *kind, const char *message) {
  av2_line("error %s %s", kind, message);
  av2_exit_now(code);
}

// --- the input -------------------------------------------------------------------------------------------------------

static void read_index(Server *s, const uint8_t *data, uint32_t length) {
  if (length == 0 || length % 4 != 0) stop(AV2_EXIT_PROTOCOL, "protocol", "the index holds no 32-bit unit numbers");
  size_t count = length / 4;
  uint32_t *raps = malloc(count * sizeof(*raps));
  if (!raps) stop(AV2_EXIT_INTERNAL, "memory", "no memory for the index");
  for (size_t i = 0; i < count; i++) {
    raps[i] = le32(data + 4 * i);
    if ((i == 0 && raps[i] != 0) || (i > 0 && raps[i] <= raps[i - 1]) || raps[i] >= s->y4m.frames)
      stop(AV2_EXIT_PROTOCOL, "protocol", "the index does not start at 0, go up, and stay below --frames");
  }
  av2_mutex_lock(&s->lock);
  if (s->raps) {
    av2_mutex_unlock(&s->lock);
    stop(AV2_EXIT_PROTOCOL, "protocol", "a second index");
  }
  s->raps = raps;
  s->rap_count = count;
  av2_cond_broadcast(&s->wake);
  av2_mutex_unlock(&s->lock);
}

static void *read_input(void *argument) {
  Server *s = argument;
  for (;;) {
    uint8_t header[16];
    size_t got = av2_stdin_read(header, sizeof(header));
    if (got < sizeof(header)) {
      // Closed by the app (or the app is gone): the end, whatever the player was doing
      av2_line("exit input-closed");
      av2_exit_now(AV2_EXIT_OK);
    }
    if (le32(header) != RECORD_MAGIC) stop(AV2_EXIT_PROTOCOL, "protocol", "a record without its AV2R mark");
    uint32_t generation = le32(header + 4), unit = le32(header + 8), length = le32(header + 12);
    if (length > RECORD_LIMIT) stop(AV2_EXIT_PROTOCOL, "protocol", "a record above 256 MiB");
    uint8_t *data = NULL;
    if (length > 0) {
      data = malloc(length);
      if (!data) stop(AV2_EXIT_INTERNAL, "memory", "no memory for a record");
      if (av2_stdin_read(data, length) < length) {
        av2_line("exit input-closed");
        av2_exit_now(AV2_EXIT_OK);
      }
    }
    if (unit == INDEX_UNIT) {
      read_index(s, data, length);
      free(data);
      continue;
    }
    av2_mutex_lock(&s->lock);
    if (!s->raps) {
      av2_mutex_unlock(&s->lock);
      stop(AV2_EXIT_PROTOCOL, "protocol", "a unit before the index");
    }
    while (generation == s->generation &&
           (s->queued_records >= QUEUE_RECORDS || (s->queued_records > 0 && s->queued_bytes >= QUEUE_BYTES)))
      av2_cond_wait(&s->wake, &s->lock);
    if (generation != s->generation) {
      // Asked for before a seek: dropped
      av2_mutex_unlock(&s->lock);
      free(data);
      continue;
    }
    Record *record = malloc(sizeof(*record));
    if (!record) stop(AV2_EXIT_INTERNAL, "memory", "no memory for a record");
    record->next = NULL;
    record->generation = generation;
    record->unit = unit;
    record->length = length;
    record->data = data;
    if (s->tail) {
      s->tail->next = record;
    } else {
      s->head = record;
    }
    s->tail = record;
    s->queued_records++;
    s->queued_bytes += length;
    av2_cond_broadcast(&s->wake);
    av2_mutex_unlock(&s->lock);
  }
  return NULL;
}

static void run_break(struct Decoder *d);

// The next record of the current generation, or NULL when a new request came first. Waiting for the app ends the
// run of the decoding speed
static Record *take_record(struct Decoder *d) {
  Server *s = d->server;
  av2_mutex_lock(&s->lock);
  if (!s->head && !s->has_pending) {
    av2_mutex_unlock(&s->lock);
    run_break(d);
    av2_mutex_lock(&s->lock);
  }
  while (!s->head && !s->has_pending) av2_cond_wait(&s->wake, &s->lock);
  Record *record = s->head;
  if (record) {
    s->head = record->next;
    if (!s->head) s->tail = NULL;
    s->queued_records--;
    s->queued_bytes -= record->length;
    av2_cond_broadcast(&s->wake);
  }
  av2_mutex_unlock(&s->lock);
  return record;
}

static void free_record_data(const uint8_t *data, void *cookie) {
  (void)cookie;
  free((void *)data);
}

// --- the decoding speed ----------------------------------------------------------------------------------------------

#define RUN_PICTURES 6
#define RUN_NS 100000000u

static void run_measure(Decoder *d) {
  Run *run = &d->run;
  if (run->pictures < run->skip + RUN_PICTURES || run->last_ns - run->first_ns < RUN_NS) return;
  double fps = (double)(run->pictures - run->skip) * 1e9 / (double)(run->last_ns - run->first_ns);
  av2_mutex_lock(&d->server->lock);
  d->server->fps = fps;
  av2_mutex_unlock(&d->server->lock);
}

// Something other than the decoder held the main thread: the run ends there
static void run_break(Decoder *d) {
  run_measure(d);
  d->run.pictures = 0;
}

static void run_picture(Decoder *d) {
  Run *run = &d->run;
  uint64_t now = av2_now_ns();
  run->pictures++;
  if (run->pictures == run->skip) run->first_ns = now;
  run->last_ns = now;
  // A long run (a computer too slow for the video) updates the speed as it goes
  if (run->pictures > run->skip && now - run->first_ns >= 5 * RUN_NS && (run->pictures - run->skip) % 8 == 0)
    run_measure(d);
}

// --- the decoder -----------------------------------------------------------------------------------------------------

static uint32_t rap_before(const Server *s, uint64_t frame) {
  size_t low = 0, high = s->rap_count;
  while (high - low > 1) {
    size_t middle = (low + high) / 2;
    if (s->raps[middle] <= frame) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return s->raps[low];
}

// Starts the decoder again at the random access unit r: a new generation, the queue emptied, "need G r" for the app
static void restart(Decoder *d, uint32_t r) {
  Server *s = d->server;
  av2_mutex_lock(&s->lock);
  s->generation++;
  uint32_t generation = s->generation;
  while (s->head) {
    Record *record = s->head;
    s->head = record->next;
    free(record->data);
    free(record);
  }
  s->tail = NULL;
  s->queued_records = 0;
  s->queued_bytes = 0;
  av2_cond_broadcast(&s->wake);
  av2_mutex_unlock(&s->lock);
  if (d->data.sz > 0) dav2d_data_unref(&d->data);
  if (d->started) dav2d_flush(d->context);
  d->started = 1;
  d->draining = 0;
  d->ended = 0;
  d->expected = r;
  d->next = r;
  d->frame_index = -1;
  av2_line("need %" PRIu32 " %" PRIu32, generation, r);
}

static uint8_t *copy_plane(uint8_t *out, const uint8_t *in, ptrdiff_t stride, int width, int height, int wide,
                           int to8) {
  for (int y = 0; y < height; y++, in += stride) {
    if (wide && to8) {
      const uint16_t *samples = (const uint16_t *)in;
      for (int x = 0; x < width; x++) {
        unsigned value = ((unsigned)samples[x] + 2) >> 2;
        out[x] = (uint8_t)(value > 255 ? 255 : value);
      }
      out += width;
    } else {
      size_t bytes = (size_t)width << wide;
      memcpy(out, in, bytes);
      out += bytes;
    }
  }
  return out;
}

static void pack(const Dav2dPicture *picture, uint8_t *out, int to8) {
  int wide = picture->p.bpc > 8, w = picture->p.w, h = picture->p.h;
  out = copy_plane(out, picture->data[0], picture->stride[0], w, h, wide, to8);
  out = copy_plane(out, picture->data[1], picture->stride[1], (w + 1) >> 1, (h + 1) >> 1, wide, to8);
  copy_plane(out, picture->data[2], picture->stride[1], (w + 1) >> 1, (h + 1) >> 1, wide, to8);
}

static void decode_failure(Decoder *d, int code) {
  char message[96];
  snprintf(message, sizeof(message), "dav2d error %d at picture %" PRId64, code, d->next);
  stop(AV2_EXIT_VIDEO, "decode", message);
}

// The next picture of the decoder, packed into frame when keep is set: 1, or 0 when a new request came while the
// decoder waited for the app, or -1 when the stream ended (the decoder is drained)
static int next_picture(Decoder *d, int keep) {
  Server *s = d->server;
  for (;;) {
    if (d->data.sz > 0) {
      int sent = dav2d_send_data(d->context, &d->data);
      if (sent < 0 && sent != DAV2D_ERR(EAGAIN)) decode_failure(d, sent);
    }
    Dav2dPicture picture;
    memset(&picture, 0, sizeof(picture));
    int got = dav2d_get_picture(d->context, &picture);
    if (got == 0) {
      const ServeOptions *o = s->options;
      if (picture.p.w != (int)o->width || picture.p.h != (int)o->height || picture.p.bpc != (int)o->bits ||
          picture.p.layout != DAV2D_PIXEL_LAYOUT_I420) {
        char message[160];
        snprintf(message, sizeof(message),
                 "picture %" PRId64 " is %dx%d, %d-bit, layout %d; serve was told %ux%u, %u-bit 4:2:0", d->next,
                 picture.p.w, picture.p.h, picture.p.bpc, (int)picture.p.layout, o->width, o->height, o->bits);
        stop(AV2_EXIT_VIDEO, "format", message);
      }
      if (keep) {
        pack(&picture, d->frame + 6, o->depth == 8 && o->bits == 10);
        d->frame_index = d->next;
      }
      dav2d_picture_unref(&picture);
      d->next++;
      run_picture(d);
      av2_mutex_lock(&s->lock);
      s->decoded++;
      av2_mutex_unlock(&s->lock);
      return 1;
    }
    if (got == DAV2D_EOF) {
      d->ended = 1;
      return -1;
    }
    if (got != DAV2D_ERR(EAGAIN)) decode_failure(d, got);
    if (d->data.sz > 0) continue;
    if (d->draining) {
      // Draining gives pictures until DAV2D_EOF; a decoder that asks for data then has none left in it
      d->ended = 1;
      return -1;
    }
    Record *record = take_record(d);
    if (!record) return 0;
    if (record->unit != d->expected) {
      char message[96];
      snprintf(message, sizeof(message), "unit %" PRIu32 " came where unit %" PRIu32 " was due", record->unit,
               d->expected);
      stop(AV2_EXIT_PROTOCOL, "protocol", message);
    }
    d->expected++;
    if (record->length == 0) {
      d->draining = 1;
      dav2d_send_data(d->context, NULL);
      free(record);
      continue;
    }
    if (dav2d_data_wrap(&d->data, record->data, record->length, free_record_data, NULL) < 0) {
      stop(AV2_EXIT_INTERNAL, "memory", "the unit could not be handed to the decoder");
    }
    free(record);
  }
}

static int pending(Server *s) {
  av2_mutex_lock(&s->lock);
  int has = s->has_pending;
  av2_mutex_unlock(&s->lock);
  return has;
}

// Picture k in frame: 1, or 0 when a new request came, or -1 when the stream has fewer pictures than --frames
static int picture(Decoder *d, uint64_t k) {
  Server *s = d->server;
  if (d->frame_index == (int64_t)k) return 1;
  uint32_t r = rap_before(s, k);
  if (!d->started || d->ended || (int64_t)k < d->next || (int64_t)r > d->next) restart(d, r);
  while (d->next <= (int64_t)k) {
    if (pending(s)) return 0;
    int got = next_picture(d, d->next == (int64_t)k);
    if (got <= 0) return got;
  }
  return 1;
}

// --- the requests ----------------------------------------------------------------------------------------------------

static int respond(av2_socket c, int status, const Y4mLayout *y4m, uint64_t start, uint64_t end) {
  char text[512];
  int length;
  if (status == 200 || status == 206) {
    char range[128] = "";
    if (status == 206) {
      snprintf(range, sizeof(range), "Content-Range: bytes %" PRIu64 "-%" PRIu64 "/%" PRIu64 "\r\n", start, end,
               y4m->total);
    }
    length = snprintf(text, sizeof(text),
                      "HTTP/1.1 %s\r\nContent-Type: video/x-yuv4mpeg\r\nAccept-Ranges: bytes\r\n%sContent-Length: "
                      "%" PRIu64 "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                      status == 206 ? "206 Partial Content" : "200 OK", range, end - start + 1);
  } else if (status == 416) {
    length = snprintf(text, sizeof(text),
                      "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%" PRIu64
                      "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                      y4m->total);
  } else {
    const char *reason = status == 403   ? "Forbidden"
                         : status == 404 ? "Not Found"
                         : status == 405 ? "Method Not Allowed"
                                         : "Bad Request";
    length = snprintf(text, sizeof(text), "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status,
                      reason);
  }
  return av2_send_all(c, text, (size_t)length);
}

static int starts_with_word(const char *line, const char *word) {
  size_t length = strlen(word);
  for (size_t i = 0; i < length; i++) {
    char c = line[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if (c != word[i]) return 0;
  }
  return 1;
}

// Range: bytes=a-b, bytes=a- or bytes=-n (the first range only); 0 when the header is not one of them
static int parse_range(const char *value, uint64_t total, uint64_t *start, uint64_t *end) {
  while (*value == ' ') value++;
  if (!starts_with_word(value, "bytes=")) return 0;
  value += 6;
  char *after = NULL;
  if (*value == '-') {
    unsigned long long suffix = strtoull(value + 1, &after, 10);
    if (after == value + 1 || suffix == 0) return 0;
    *start = suffix >= total ? 0 : total - suffix;
    *end = total - 1;
    return 1;
  }
  unsigned long long first = strtoull(value, &after, 10);
  if (after == value || *after != '-') return 0;
  *start = first;
  value = after + 1;
  if (*value >= '0' && *value <= '9') {
    unsigned long long last = strtoull(value, &after, 10);
    *end = last >= total ? total - 1 : last;
  } else {
    *end = total - 1;
  }
  return 1;
}

static void *accept_requests(void *argument) {
  Server *s = argument;
  for (;;) {
    int loopback = 0;
    av2_socket c = av2_accept(s->listener, &loopback);
    if (c == AV2_NO_SOCKET) {
      av2_sleep_ms(10);
      continue;
    }
    if (!loopback) {
      av2_line("refused address");
      av2_socket_close(c);
      continue;
    }
    av2_socket_timeout(c, 2000);
    char text[REQUEST_LIMIT + 1];
    size_t used = 0;
    while (used < REQUEST_LIMIT) {
      long got = av2_recv(c, text + used, REQUEST_LIMIT - used);
      if (got <= 0) break;
      used += (size_t)got;
      text[used] = '\0';
      if (strstr(text, "\r\n\r\n")) break;
    }
    text[used] = '\0';
    char method[8] = "", target[256] = "";
    if (!strstr(text, "\r\n\r\n") || sscanf(text, "%7s %255s", method, target) != 2) {
      respond(c, 400, &s->y4m, 0, 0);
      av2_line("refused request");
      av2_socket_close(c);
      continue;
    }
    int head = strcmp(method, "HEAD") == 0;
    if (!head && strcmp(method, "GET") != 0) {
      respond(c, 405, &s->y4m, 0, 0);
      av2_line("refused method");
      av2_socket_close(c);
      continue;
    }
    if (strcmp(target, s->path) != 0) {
      // Another token, or another file under the token
      const char *token = s->options->token;
      size_t length = strlen(token);
      int token_matches = target[0] == '/' && strncmp(target + 1, token, length) == 0 && target[length + 1] == '/';
      respond(c, token_matches ? 404 : 403, &s->y4m, 0, 0);
      av2_line(token_matches ? "refused path" : "refused token");
      av2_socket_close(c);
      continue;
    }
    Request request;
    request.socket = c;
    request.start = 0;
    request.end = s->y4m.total - 1;
    request.ranged = 0;
    for (char *line = strstr(text, "\r\n"); line && line[2] && !(line[2] == '\r' && line[3] == '\n');
         line = strstr(line + 2, "\r\n")) {
      if (starts_with_word(line + 2, "range:")) {
        request.ranged = 1;
        if (!parse_range(line + 2 + 6, s->y4m.total, &request.start, &request.end) || request.start > request.end ||
            request.start >= s->y4m.total) {
          respond(c, 416, &s->y4m, 0, 0);
          av2_line("refused range");
          request.socket = AV2_NO_SOCKET;
        }
        break;
      }
    }
    if (request.socket == AV2_NO_SOCKET) {
      av2_socket_close(c);
      continue;
    }
    if (head) {
      respond(c, request.ranged ? 206 : 200, &s->y4m, request.start, request.end);
      av2_socket_close(c);
      continue;
    }
    av2_socket_timeout(c, 0);
    av2_mutex_lock(&s->lock);
    if (s->has_pending) av2_socket_close(s->pending.socket);
    s->pending = request;
    s->has_pending = 1;
    // The request being served is over: its blocked write fails at once
    if (s->serving != AV2_NO_SOCKET) av2_socket_shutdown(s->serving);
    av2_cond_broadcast(&s->wake);
    av2_mutex_unlock(&s->lock);
  }
  return NULL;
}

// Writes the bytes of a picture, 256 KiB at a time. A write that takes more than 10 ms (less than 25 MB/s) means a
// player that does not read (its cache is full, or it is paused): that ends the run of the decoding speed. Faster ones
// are the copy to the player, part of what serving costs
#define WRITE_CHUNK ((size_t)256 << 10)
#define HELD_NS 10000000u

static int send_picture(Decoder *d, av2_socket socket, const uint8_t *data, size_t size) {
  while (size > 0) {
    size_t chunk = size < WRITE_CHUNK ? size : WRITE_CHUNK;
    uint64_t started = av2_now_ns();
    if (av2_send_all(socket, data, chunk) != 0) return -1;
    if (av2_now_ns() - started > HELD_NS) run_break(d);
    data += chunk;
    size -= chunk;
  }
  return 0;
}

static void serve_request(Decoder *d, const Request *request) {
  Server *s = d->server;
  const Y4mLayout *y4m = &s->y4m;
  uint64_t at = request->start, end = request->end;
  if (respond(request->socket, request->ranged ? 206 : 200, y4m, at, end) != 0) return;
  uint64_t k0 = at < y4m->header_length ? 0 : (at - y4m->header_length) / y4m->record_bytes;
  av2_line("request bytes=%" PRIu64 "-%" PRIu64 " frame=%" PRIu64, at, end, k0);
  if (at < y4m->header_length) {
    uint64_t stop_at = end + 1 < y4m->header_length ? end + 1 : y4m->header_length;
    if (av2_send_all(request->socket, y4m->header + at, (size_t)(stop_at - at)) != 0) return;
    at = stop_at;
  }
  // The index comes right after the start: a request before it waits for it
  av2_mutex_lock(&s->lock);
  while (!s->raps && !s->has_pending) av2_cond_wait(&s->wake, &s->lock);
  int ready = s->raps != NULL;
  av2_mutex_unlock(&s->lock);
  if (!ready) return;
  while (at <= end) {
    if (pending(s)) return;
    uint64_t k = (at - y4m->header_length) / y4m->record_bytes;
    uint64_t offset = (at - y4m->header_length) % y4m->record_bytes;
    int got = picture(d, k);
    if (got == 0) return;
    if (got < 0) {
      char message[96];
      snprintf(message, sizeof(message), "the stream ended at picture %" PRId64 ", --frames is %" PRIu64, d->next,
               y4m->frames);
      av2_line("error short %s", message);
      return;
    }
    uint64_t size = y4m->record_bytes - offset;
    if (size > end - at + 1) size = end - at + 1;
    if (send_picture(d, request->socket, d->frame + offset, (size_t)size) != 0) return;
    at += size;
    av2_mutex_lock(&s->lock);
    if (offset + size == y4m->record_bytes) s->served++;
    s->position = (int64_t)k + 1;
    av2_mutex_unlock(&s->lock);
  }
}

// --- the report ------------------------------------------------------------------------------------------------------

static void *report(void *argument) {
  Server *s = argument;
  const char *simd = av2_simd_level();
  for (;;) {
    av2_sleep_ms(500);
    av2_mutex_lock(&s->lock);
    uint64_t decoded = s->decoded, served = s->served;
    uint32_t generation = s->generation;
    int64_t position = s->position;
    int serving = s->serving != AV2_NO_SOCKET;
    double fps = s->fps;
    av2_mutex_unlock(&s->lock);
    av2_line("stat decoded=%" PRIu64 " served=%" PRIu64 " fps=%.1f simd=%s gen=%" PRIu32 " frame=%" PRId64
             " serving=%d",
             decoded, served, fps, simd, generation, position, serving);
  }
  return NULL;
}

// --- serve -----------------------------------------------------------------------------------------------------------

int av2_serve(const ServeOptions *o) {
  Server *s = &server;
  memset(s, 0, sizeof(*s));
  s->options = o;
  s->serving = AV2_NO_SOCKET;
  s->position = 0;
  unsigned served_bits = o->depth == 8 ? 8 : o->bits;
  if (!y4m_layout(&s->y4m, o->width, o->height, served_bits, o->fps_num, o->fps_den, o->full_range, o->frames)) {
    fprintf(stderr, "immuch360-av2: these numbers make no y4m\n");
    return AV2_EXIT_USAGE;
  }
  if (o->frame_bytes && o->frame_bytes != s->y4m.frame_bytes) {
    fprintf(stderr, "immuch360-av2: a picture takes %zu bytes, --frame-bytes says %" PRIu64 "\n", s->y4m.frame_bytes,
            o->frame_bytes);
    return AV2_EXIT_USAGE;
  }
  snprintf(s->path, sizeof(s->path), "/%s/video.y4m", o->token);
  av2_mutex_init(&s->lock);
  av2_cond_init(&s->wake);

  Decoder d;
  memset(&d, 0, sizeof(d));
  d.server = s;
  d.frame_index = -1;
  d.frame = malloc(s->y4m.record_bytes);
  if (!d.frame) {
    av2_line("error memory no memory for a picture of %zu bytes", s->y4m.record_bytes);
    return AV2_EXIT_INTERNAL;
  }
  memcpy(d.frame, "FRAME\n", 6);
  Dav2dSettings settings;
  dav2d_default_settings(&settings);
  settings.n_threads = o->threads;
  settings.all_layers = 0;
  if (dav2d_open(&d.context, &settings) < 0) {
    av2_line("error decode the decoder could not start");
    return AV2_EXIT_INTERNAL;
  }
  int delay = dav2d_get_frame_delay(&settings);
  d.run.skip = delay > 0 ? (unsigned)delay : 1;

  unsigned port = 0;
  s->listener = av2_listen_loopback(o->port, &port);
  if (s->listener == AV2_NO_SOCKET) {
    av2_line("error network no socket on 127.0.0.1");
    return AV2_EXIT_NETWORK;
  }
  av2_line("listening %u address=127.0.0.1 length=%" PRIu64 " header=%zu frame=%zu frames=%" PRIu64, port,
           s->y4m.total, s->y4m.header_length, s->y4m.frame_bytes, s->y4m.frames);
  av2_thread input_thread, accept_thread, report_thread;
  if (av2_thread_start(&input_thread, read_input, s) != 0 ||
      av2_thread_start(&accept_thread, accept_requests, s) != 0 || av2_thread_start(&report_thread, report, s) != 0) {
    av2_line("error thread a thread could not start");
    return AV2_EXIT_INTERNAL;
  }

  for (;;) {
    av2_mutex_lock(&s->lock);
    while (!s->has_pending) av2_cond_wait(&s->wake, &s->lock);
    Request request = s->pending;
    s->has_pending = 0;
    s->serving = request.socket;
    av2_mutex_unlock(&s->lock);
    run_break(&d);
    serve_request(&d, &request);
    run_break(&d);
    av2_mutex_lock(&s->lock);
    s->serving = AV2_NO_SOCKET;
    av2_mutex_unlock(&s->lock);
    av2_socket_close(request.socket);
  }
}
