#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "scheme.h"

extern char _binary_petite_boot_start[], _binary_petite_boot_end[];
extern char _binary_scheme_boot_start[], _binary_scheme_boot_end[];
extern char _binary_tuna_boot_start[], _binary_tuna_boot_end[];

/* Chez runs its signal handlers only once the main thread runs Scheme code
   again, which an idle Tuna never does, so a taken signal is written to a
   pipe that a thread of the kernel waits on. The write end never blocks: a
   handler that waited for a full pipe would never return. */
static int signal_pipe[2];

static void write_signal(int sig) {
  int saved = errno;
  unsigned char number = (unsigned char)sig;
  ssize_t written = write(signal_pipe[1], &number, 1);
  (void)written;
  errno = saved;
}

/* SA_RESTART, so that a signal cuts short fewer of other threads' system calls. */
static int tuna_take_signal(int sig) {
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = write_signal;
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_RESTART;
  return sigaction(sig, &action, NULL);
}

static int tuna_wait_signal(void) {
  unsigned char number;
  for (;;) {
    ssize_t n = read(signal_pipe[0], &number, 1);
    if (n == 1) return number;
    if (n < 0 && errno == EINTR) continue;
    return -1;
  }
}

int main(int argc, const char *argv[]) {
  if (pipe2(signal_pipe, O_CLOEXEC) != 0) return 1;
  if (fcntl(signal_pipe[1], F_SETFL, O_NONBLOCK) != 0) return 1;
  Sscheme_init(0);
  Sregister_boot_file_bytes("petite", _binary_petite_boot_start,
                            _binary_petite_boot_end - _binary_petite_boot_start);
  Sregister_boot_file_bytes("scheme", _binary_scheme_boot_start,
                            _binary_scheme_boot_end - _binary_scheme_boot_start);
  Sregister_boot_file_bytes("tuna", _binary_tuna_boot_start,
                            _binary_tuna_boot_end - _binary_tuna_boot_start);
  Sbuild_heap(argv[0], 0);
  Sforeign_symbol("tuna_take_signal", (void *)tuna_take_signal);
  Sforeign_symbol("tuna_wait_signal", (void *)tuna_wait_signal);
  /* Chez gives scheme-start every argument but argv[0], and Tuna's own
     library is found beside the program, so its path goes first. */
  char resolved[PATH_MAX];
  const char *program = realpath("/proc/self/exe", resolved) ? resolved : argv[0];
  const char **arguments = malloc((argc + 2) * sizeof(char *));
  if (arguments == NULL) return 1;
  arguments[0] = argv[0];
  arguments[1] = program;
  for (int i = 1; i <= argc; i++) arguments[i + 1] = argv[i];
  int status = Sscheme_start(argc + 1, arguments);
  Sscheme_deinit();
  return status;
}
