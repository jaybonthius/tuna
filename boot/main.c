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
  int status = Sscheme_start(argc, argv);
  Sscheme_deinit();
  return status;
}
