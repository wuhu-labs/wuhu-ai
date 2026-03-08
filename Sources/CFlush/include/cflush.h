#include <stdio.h>

static inline void cflush_stdout(void) {
  fflush(stdout);
}

static inline void cflush_disable_buffering(void) {
  setbuf(stdout, NULL);
}
