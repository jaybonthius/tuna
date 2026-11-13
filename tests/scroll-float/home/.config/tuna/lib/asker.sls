#!tuna
;; Shows a palette through a display rule without importing layout-float,
;; so a test can unload layout-float before it.
(import (layout) (buffers))

(define (ask!)
  (layout:display-buffer (or (buffers:find "*asked*") (buffers:make "*asked*" "Name: \n"))))
