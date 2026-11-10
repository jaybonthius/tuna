(import (chezscheme) (tuna main))

;; A boot file loads before Chez finishes starting, so it must not run the
;; program itself; Chez calls scheme-start once it has.
(suppress-greeting #t)
(scheme-start (lambda arguments (main arguments)))
