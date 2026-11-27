#!tuna
;; Shows popups as a completion plugin would, so a test can unload it.
(import (layout-float) (buffers))

(define (show! view)
  (layout-float:show-at! view 1 (or (buffers:find "*popper*") (buffers:make "*popper*" "p\n")) 1/2 1/2))
