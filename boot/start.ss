(import (chezscheme) (tuna main))

;; A boot file loads before Chez finishes starting, so it must not run the
;; program itself; Chez calls scheme-start once it has.
(suppress-greeting #t)
(scheme-start
  (lambda (program . arguments)
    ;; Tuna's and chez-lang's libraries are all in the boot file, so none is
    ;; looked for on disk.
    (main program arguments '())))
