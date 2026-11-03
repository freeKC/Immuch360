// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// What immuch360-av2 needs from the system, the same on Windows, Linux and macOS: threads, a mutex and a condition,
// a monotonic clock, the loopback socket of the server, the raw standard input and whether its writer left, the end
// of another process, the lines of the standard output, and the SIMD level of the processor as dav2d sees it.
#ifndef IMMUCH360_AV2_PLATFORM_H
#define IMMUCH360_AV2_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef SOCKET av2_socket;
#define AV2_NO_SOCKET INVALID_SOCKET
typedef CRITICAL_SECTION av2_mutex;
typedef CONDITION_VARIABLE av2_cond;
typedef HANDLE av2_thread;
#else
#include <pthread.h>
typedef int av2_socket;
#define AV2_NO_SOCKET (-1)
typedef pthread_mutex_t av2_mutex;
typedef pthread_cond_t av2_cond;
typedef pthread_t av2_thread;
#endif

// Exit codes of the program, named in the README and by the app
enum {
  AV2_EXIT_OK = 0,           // the input or the output closed, or the --parent process ended: the app is done
  AV2_EXIT_INTERNAL = 1,     // out of memory, a thread that could not start
  AV2_EXIT_USAGE = 2,        // bad arguments
  AV2_EXIT_VIDEO = 3,        // the video could not be decoded, or is not what serve was told
  AV2_EXIT_NETWORK = 4,      // no listening socket on 127.0.0.1
  AV2_EXIT_PROTOCOL = 5,     // the records of the standard input are not the protocol's
};

void av2_platform_init(void);

void av2_mutex_init(av2_mutex *m);
void av2_mutex_lock(av2_mutex *m);
void av2_mutex_unlock(av2_mutex *m);
void av2_cond_init(av2_cond *c);
void av2_cond_wait(av2_cond *c, av2_mutex *m);
// Waits at most ms milliseconds of the monotonic clock; spurious and timed out wakes look the same to the caller, who
// checks its state
void av2_cond_timedwait(av2_cond *c, av2_mutex *m, unsigned ms);
void av2_cond_broadcast(av2_cond *c);
// Starts a detached thread (never joined)
int av2_thread_start(av2_thread *t, void *(*run)(void *), void *arg);

// Nanoseconds of a monotonic clock
uint64_t av2_now_ns(void);
void av2_sleep_ms(unsigned ms);

// Reads exactly size bytes of the standard input; returns the bytes read, less than size at its end or on an error
size_t av2_stdin_read(void *buffer, size_t size);
// Whether the writer of the standard input has gone, even while bytes it wrote still wait in the pipe, where a read
// would only see the end after them: POLLHUP of poll on Linux, EV_EOF of kqueue on macOS, the closing state of the
// pipe on Windows. 0 when it cannot be told (a file, a console), where the reads see the end
int av2_stdin_closed(void);

// Blocks until the process pid has ended, at once when there is none: 0, or -1 when it cannot be watched
int av2_wait_process(unsigned long pid);

// One line on the standard output, flushed, never mixed with a line of another thread. A line that cannot be written
// ends the program (code 0): nobody reads them any more, the app is gone
void av2_line(const char *format, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;

// Flushes the standard output and ends the process at once, whatever the other threads do
void av2_exit_now(int code);

// The listening socket on 127.0.0.1 (port 0: any free port); the port it got in *bound
av2_socket av2_listen_loopback(unsigned port, unsigned *bound);
// The next connection, and whether it comes from 127.0.0.1
av2_socket av2_accept(av2_socket listener, int *from_loopback);
int av2_send_all(av2_socket s, const void *data, size_t size);
long av2_recv(av2_socket s, void *buffer, size_t size);
void av2_socket_timeout(av2_socket s, unsigned ms);
// Ends the connection s while another thread may be blocked writing to it: that write fails at once, on Windows too
void av2_socket_shutdown(av2_socket s);
void av2_socket_close(av2_socket s);

// The SIMD level dav2d picks on this processor: avx512icl, avx2, sse41, ssse3, sse2, neon or c
const char *av2_simd_level(void);
// Every level the processor has, separated by spaces
const char *av2_simd_all(void);

#endif
