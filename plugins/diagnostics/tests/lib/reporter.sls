#!tuna
;; Its own module, so unloading it can be tested.
(import (buffers) (document) (diagnostics))

(define %source (diagnostics:make-source))

(define (report-bad! b)
  (diagnostics:report! %source b
    (list (diagnostics:make-diagnostic '(2 . 0) '(2 . 5) (diagnostics:severity error) "bad"))))
