// Preloaded into omanotes-db by lib/stub-db.sh: the Nth open of a SQLite
// rollback journal never returns, as a write stuck on a disk. N is
// OMANOTES_STALL_JOURNAL. Each write opens the journal once, so N = 2 lets the
// first write of a request commit and holds the second until a signal.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int opened;

static void maybe_stall(const char *path) {
  const char *n = getenv("OMANOTES_STALL_JOURNAL");
  size_t len = path ? strlen(path) : 0;
  if (!n || len < 8 || strcmp(path + len - 8, "-journal") != 0) return;
  if (++opened == atoi(n)) for (;;) pause();
}

static mode_t mode_of(int flags, va_list ap) {
  return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE ? va_arg(ap, mode_t) : 0;
}

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);

#define FORWARD(type, name, ...) \
  static type real; \
  if (!real) real = (type)dlsym(RTLD_NEXT, name); \
  return real(__VA_ARGS__)

int open(const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = mode_of(flags, ap);
  va_end(ap);
  maybe_stall(path);
  FORWARD(open_fn, "open", path, flags, mode);
}

int open64(const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = mode_of(flags, ap);
  va_end(ap);
  maybe_stall(path);
  FORWARD(open_fn, "open64", path, flags, mode);
}

int openat(int dir, const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = mode_of(flags, ap);
  va_end(ap);
  maybe_stall(path);
  FORWARD(openat_fn, "openat", dir, path, flags, mode);
}

int openat64(int dir, const char *path, int flags, ...) {
  va_list ap;
  va_start(ap, flags);
  mode_t mode = mode_of(flags, ap);
  va_end(ap);
  maybe_stall(path);
  FORWARD(openat_fn, "openat64", dir, path, flags, mode);
}
