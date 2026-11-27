(library (tuna version)
  (export tuna-version)
  (import (chezscheme))

  ;; build.ss writes version.txt from git describe, so the version always
  ;; names the commit Tuna was built from.
  (define tuna-version (include "version.txt")))
