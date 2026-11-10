#include <limits.h>
#include <stdlib.h>
#include "scheme.h"

extern char _binary_petite_boot_start[], _binary_petite_boot_end[];
extern char _binary_scheme_boot_start[], _binary_scheme_boot_end[];
extern char _binary_tuna_boot_start[], _binary_tuna_boot_end[];

int main(int argc, const char *argv[]) {
  Sscheme_init(0);
  Sregister_boot_file_bytes("petite", _binary_petite_boot_start,
                            _binary_petite_boot_end - _binary_petite_boot_start);
  Sregister_boot_file_bytes("scheme", _binary_scheme_boot_start,
                            _binary_scheme_boot_end - _binary_scheme_boot_start);
  Sregister_boot_file_bytes("tuna", _binary_tuna_boot_start,
                            _binary_tuna_boot_end - _binary_tuna_boot_start);
  Sbuild_heap(argv[0], 0);
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
