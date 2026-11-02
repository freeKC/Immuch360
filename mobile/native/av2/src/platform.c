// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// The system calls behind platform.h: Win32 and Winsock on Windows, POSIX threads and BSD sockets elsewhere.
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE  // syscall() of glibc
#define _DARWIN_C_SOURCE
#endif

#include "platform.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <process.h>
#else
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#endif
#endif

#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
#define AV2_X86 1
#elif (defined(__GNUC__) || defined(__clang__)) && (defined(__x86_64__) || defined(__i386__))
#include <cpuid.h>
#define AV2_X86 1
#endif

static av2_mutex output_lock;

void av2_platform_init(void) {
  av2_mutex_init(&output_lock);
#ifdef _WIN32
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
#else
  // A client that goes away while we write must give an error, not a signal that ends the program
  signal(SIGPIPE, SIG_IGN);
#endif
}

#ifdef _WIN32
void av2_mutex_init(av2_mutex *m) { InitializeCriticalSection(m); }
void av2_mutex_lock(av2_mutex *m) { EnterCriticalSection(m); }
void av2_mutex_unlock(av2_mutex *m) { LeaveCriticalSection(m); }
void av2_cond_init(av2_cond *c) { InitializeConditionVariable(c); }
void av2_cond_wait(av2_cond *c, av2_mutex *m) { SleepConditionVariableCS(c, m, INFINITE); }
void av2_cond_timedwait(av2_cond *c, av2_mutex *m, unsigned ms) { SleepConditionVariableCS(c, m, ms); }
void av2_cond_broadcast(av2_cond *c) { WakeAllConditionVariable(c); }

typedef struct {
  void *(*run)(void *);
  void *arg;
} ThreadStart;

static DWORD WINAPI thread_trampoline(LPVOID parameter) {
  ThreadStart start = *(ThreadStart *)parameter;
  free(parameter);
  start.run(start.arg);
  return 0;
}

int av2_thread_start(av2_thread *t, void *(*run)(void *), void *arg) {
  ThreadStart *start = malloc(sizeof(*start));
  if (!start) return -1;
  start->run = run;
  start->arg = arg;
  HANDLE thread = CreateThread(NULL, 0, thread_trampoline, start, 0, NULL);
  if (!thread) {
    free(start);
    return -1;
  }
  // Never joined: its handle goes at once, as pthread_detach does elsewhere
  CloseHandle(thread);
  *t = NULL;
  return 0;
}

uint64_t av2_now_ns(void) {
  static LARGE_INTEGER frequency;
  LARGE_INTEGER counter;
  if (!frequency.QuadPart) QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  return (uint64_t)((double)counter.QuadPart * 1e9 / (double)frequency.QuadPart);
}

void av2_sleep_ms(unsigned ms) { Sleep(ms); }

size_t av2_stdin_read(void *buffer, size_t size) {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  size_t done = 0;
  while (done < size) {
    DWORD chunk = size - done > (1u << 30) ? (1u << 30) : (DWORD)(size - done);
    DWORD got = 0;
    if (!ReadFile(input, (char *)buffer + done, chunk, &got, NULL) || got == 0) break;
    done += got;
  }
  return done;
}

int av2_stdin_closed(void) {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  if (input == NULL || input == INVALID_HANDLE_VALUE || GetFileType(input) != FILE_TYPE_PIPE) return 0;
  // A pipe that still holds bytes reads them before it tells that its writer left (PeekNamedPipe too); its state says
  // it at once: NtQueryInformationFile of ntdll, looked up here (nothing more to import), FilePipeLocalInformation
  // (24), whose NamedPipeState becomes FILE_PIPE_CLOSING_STATE (4) when the other end closes, whether the app made the
  // pipe with CreatePipe or as dart:io does (a named pipe, overlapped)
  typedef LONG(WINAPI * QueryInformationFile)(HANDLE, void *, void *, ULONG, int);
  static QueryInformationFile query;
  if (!query) {
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (ntdll) query = (QueryInformationFile)(void (*)(void))GetProcAddress(ntdll, "NtQueryInformationFile");
    if (!query) return 0;
  }
  struct {
    void *status;
    ULONG_PTR information;
  } io;
  ULONG pipe[10];  // FILE_PIPE_LOCAL_INFORMATION, ten ULONGs: NamedPipeState is the ninth
  if (query(input, &io, pipe, sizeof(pipe), 24) < 0) return 0;
  return pipe[8] == 4;
}

int av2_wait_process(unsigned long pid) {
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
  if (!process) return GetLastError() == ERROR_INVALID_PARAMETER ? 0 : -1;
  WaitForSingleObject(process, INFINITE);
  CloseHandle(process);
  return 0;
}
#else
void av2_mutex_init(av2_mutex *m) { pthread_mutex_init(m, NULL); }
void av2_mutex_lock(av2_mutex *m) { pthread_mutex_lock(m); }
void av2_mutex_unlock(av2_mutex *m) { pthread_mutex_unlock(m); }
void av2_cond_init(av2_cond *c) { pthread_cond_init(c, NULL); }
void av2_cond_wait(av2_cond *c, av2_mutex *m) { pthread_cond_wait(c, m); }

void av2_cond_timedwait(av2_cond *c, av2_mutex *m, unsigned ms) {
  struct timeval now;
  gettimeofday(&now, NULL);
  uint64_t ns = (uint64_t)now.tv_usec * 1000u + (uint64_t)ms * 1000000u;
  struct timespec until;
  until.tv_sec = now.tv_sec + (time_t)(ns / 1000000000u);
  until.tv_nsec = (long)(ns % 1000000000u);
  pthread_cond_timedwait(c, m, &until);
}

void av2_cond_broadcast(av2_cond *c) { pthread_cond_broadcast(c); }

int av2_thread_start(av2_thread *t, void *(*run)(void *), void *arg) {
  if (pthread_create(t, NULL, run, arg) != 0) return -1;
  pthread_detach(*t);
  return 0;
}

uint64_t av2_now_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}

void av2_sleep_ms(unsigned ms) {
  struct timespec wait = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
  while (nanosleep(&wait, &wait) != 0 && errno == EINTR) {
  }
}

size_t av2_stdin_read(void *buffer, size_t size) {
  size_t done = 0;
  while (done < size) {
    ssize_t got = read(0, (char *)buffer + done, size - done);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) break;
    done += (size_t)got;
  }
  return done;
}

int av2_stdin_closed(void) {
#if defined(__APPLE__)
  int queue = kqueue();
  if (queue < 0) return 0;
  struct kevent change, event;
  EV_SET(&change, 0, EVFILT_READ, EV_ADD, 0, 0, NULL);
  struct timespec now = {0, 0};
  int got = kevent(queue, &change, 1, &event, 1, &now);
  close(queue);
  return got > 0 && !(event.flags & EV_ERROR) && (event.flags & EV_EOF);
#else
  struct pollfd input = {0, POLLIN, 0};
  int got;
  do {
    got = poll(&input, 1, 0);
  } while (got < 0 && errno == EINTR);
  return got > 0 && (input.revents & POLLHUP);
#endif
}

int av2_wait_process(unsigned long pid) {
#if defined(__APPLE__)
  int queue = kqueue();
  if (queue < 0) return -1;
  struct kevent change, event;
  EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  if (kevent(queue, &change, 1, NULL, 0, NULL) < 0) {
    int gone = errno == ESRCH;
    close(queue);
    return gone ? 0 : -1;
  }
  while (kevent(queue, NULL, 0, &event, 1, NULL) < 0 && errno == EINTR) {
  }
  close(queue);
  return 0;
#else
#if defined(__linux__) && defined(SYS_pidfd_open)
  int process = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
  if (process >= 0) {
    // Readable when the process ends
    struct pollfd watch = {process, POLLIN, 0};
    while (poll(&watch, 1, -1) < 0 && errno == EINTR) {
    }
    close(process);
    return 0;
  }
  if (errno == ESRCH) return 0;
#endif
  // A kernel without pidfd (before Linux 5.3): asked every 200 ms
  for (;;) {
    if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) return 0;
    av2_sleep_ms(200);
  }
#endif
}
#endif

void av2_line(const char *format, ...) {
  va_list arguments;
  av2_mutex_lock(&output_lock);
  va_start(arguments, format);
  int failed = vfprintf(stdout, format, arguments) < 0;
  va_end(arguments);
  if (fputc('\n', stdout) == EOF) failed = 1;
  if (fflush(stdout) != 0) failed = 1;
  // The other end of the pipe closed: the app is gone, even if something else still holds the standard input open.
  // serve writes a stat line every half second, so it ends within half a second of the app
  if (failed) _exit(AV2_EXIT_OK);
  av2_mutex_unlock(&output_lock);
}

void av2_exit_now(int code) {
  av2_mutex_lock(&output_lock);
  fflush(stdout);
  fflush(stderr);
  _exit(code);
}

// --- sockets ---------------------------------------------------------------------------------------------------------

av2_socket av2_listen_loopback(unsigned port, unsigned *bound) {
  av2_socket s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == AV2_NO_SOCKET) return AV2_NO_SOCKET;
#ifdef _WIN32
  // No other program may bind the same port while we listen on it
  BOOL exclusive = TRUE;
  setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof(exclusive));
#endif
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((unsigned short)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(s, 8) != 0) {
    av2_socket_close(s);
    return AV2_NO_SOCKET;
  }
  socklen_t length = sizeof(address);
  if (getsockname(s, (struct sockaddr *)&address, &length) != 0) {
    av2_socket_close(s);
    return AV2_NO_SOCKET;
  }
  *bound = ntohs(address.sin_port);
  return s;
}

av2_socket av2_accept(av2_socket listener, int *from_loopback) {
  struct sockaddr_in peer;
  socklen_t length = sizeof(peer);
  av2_socket s = accept(listener, (struct sockaddr *)&peer, &length);
  if (s == AV2_NO_SOCKET) return s;
  *from_loopback = peer.sin_family == AF_INET && ntohl(peer.sin_addr.s_addr) == INADDR_LOOPBACK;
#if defined(__APPLE__)
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
  // Big frames: a larger buffer lets one send move more of them per call
  int buffer = 4 << 20;
  setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&buffer, sizeof(buffer));
  return s;
}

int av2_send_all(av2_socket s, const void *data, size_t size) {
  const char *at = data;
  while (size > 0) {
    int chunk = size > (1u << 30) ? (1 << 30) : (int)size;
#ifdef _WIN32
    int sent = send(s, at, chunk, 0);
#elif defined(MSG_NOSIGNAL)
    ssize_t sent = send(s, at, (size_t)chunk, MSG_NOSIGNAL);
    if (sent < 0 && errno == EINTR) continue;
#else
    ssize_t sent = send(s, at, (size_t)chunk, 0);
    if (sent < 0 && errno == EINTR) continue;
#endif
    if (sent <= 0) return -1;
    at += sent;
    size -= (size_t)sent;
  }
  return 0;
}

long av2_recv(av2_socket s, void *buffer, size_t size) {
#ifdef _WIN32
  return recv(s, buffer, (int)size, 0);
#else
  ssize_t got;
  do {
    got = recv(s, buffer, size, 0);
  } while (got < 0 && errno == EINTR);
  return (long)got;
#endif
}

void av2_socket_timeout(av2_socket s, unsigned ms) {
#ifdef _WIN32
  DWORD value = ms;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&value, sizeof(value));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&value, sizeof(value));
#else
  struct timeval value = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000L};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &value, sizeof(value));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &value, sizeof(value));
#endif
}

void av2_socket_shutdown(av2_socket s) {
#ifdef _WIN32
  shutdown(s, SD_BOTH);
#else
  shutdown(s, SHUT_RDWR);
#endif
}

void av2_socket_close(av2_socket s) {
#ifdef _WIN32
  closesocket(s);
#else
  close(s);
#endif
}

// --- SIMD ------------------------------------------------------------------------------------------------------------

#define BITS(value, mask) (((value) & (mask)) == (mask))

enum { SIMD_SSE2 = 1, SIMD_SSSE3 = 2, SIMD_SSE41 = 4, SIMD_AVX2 = 8, SIMD_AVX512ICL = 16, SIMD_NEON = 32 };

#ifdef AV2_X86
static void cpuid(unsigned leaf, unsigned subleaf, unsigned r[4]) {
#ifdef _MSC_VER
  int out[4];
  __cpuidex(out, (int)leaf, (int)subleaf);
  r[0] = (unsigned)out[0];
  r[1] = (unsigned)out[1];
  r[2] = (unsigned)out[2];
  r[3] = (unsigned)out[3];
#else
  __cpuid_count(leaf, subleaf, r[0], r[1], r[2], r[3]);
#endif
}

static uint64_t xgetbv0(void) {
#ifdef _MSC_VER
  return _xgetbv(0);
#else
  unsigned low, high;
  __asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
  return ((uint64_t)high << 32) | low;
#endif
}
#endif

// The tests of src/x86/cpu.c of dav2d at the commit of the lock, so that the level said is the one it uses
static unsigned simd_flags(void) {
  unsigned flags = 0;
#ifdef AV2_X86
  unsigned r[4];  // eax, ebx, ecx, edx
  cpuid(0, 0, r);
  unsigned max_leaf = r[0];
  if (max_leaf >= 1) {
    cpuid(1, 0, r);
    unsigned ecx = r[2], edx = r[3];
    if (BITS(edx, 0x06008000u)) {
      flags |= SIMD_SSE2;
      if (BITS(ecx, 0x00000201u)) {
        flags |= SIMD_SSSE3;
        if (BITS(ecx, 0x00080000u)) flags |= SIMD_SSE41;
      }
    }
#if defined(__x86_64__) || defined(_M_X64)
    if (BITS(ecx, 0x18000000u)) {
      uint64_t xcr0 = xgetbv0();
      if (BITS(xcr0, 0x6u) && max_leaf >= 7) {
        cpuid(7, 0, r);
        if (BITS(r[1], 0x00000128u)) {
          flags |= SIMD_AVX2;
          if (BITS(xcr0, 0xe0u) && BITS(r[1], 0xd0230000u) && BITS(r[2], 0x00005f42u)) flags |= SIMD_AVX512ICL;
        }
      }
    }
#endif
  }
#elif defined(__aarch64__) || defined(_M_ARM64)
  flags |= SIMD_NEON;
#endif
  return flags;
}

const char *av2_simd_level(void) {
  unsigned flags = simd_flags();
  if (flags & SIMD_AVX512ICL) return "avx512icl";
  if (flags & SIMD_AVX2) return "avx2";
  if (flags & SIMD_SSE41) return "sse41";
  if (flags & SIMD_SSSE3) return "ssse3";
  if (flags & SIMD_SSE2) return "sse2";
  if (flags & SIMD_NEON) return "neon";
  return "c";
}

const char *av2_simd_all(void) {
  static char text[64];
  unsigned flags = simd_flags();
  text[0] = '\0';
  static const struct {
    unsigned flag;
    const char *name;
  } names[] = {{SIMD_SSE2, "sse2"},   {SIMD_SSSE3, "ssse3"},         {SIMD_SSE41, "sse41"},
               {SIMD_AVX2, "avx2"},   {SIMD_AVX512ICL, "avx512icl"}, {SIMD_NEON, "neon"}};
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    if (!(flags & names[i].flag)) continue;
    if (text[0]) strcat(text, " ");
    strcat(text, names[i].name);
  }
  if (!text[0]) strcpy(text, "none");
  return text;
}
