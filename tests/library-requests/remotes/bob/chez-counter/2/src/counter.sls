(library (counter)
  (export counter-version)
  (import (chezscheme) (base))
  (define (counter-version) (string-append "2 with " (base-name))))
