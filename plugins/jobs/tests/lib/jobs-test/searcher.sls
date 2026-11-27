#!tuna
(import (jobs))

;; The critical wind's out, which a stop cannot skip, writes the file a
;; test waits for.
(jobs:define-worker (count-slowly path emit)
  (dynamic-wind #t
    void
    (lambda ()
      (let loop ([i 0])
        (emit i)
        (sleep (make-time 'time-duration 10000000 0))
        (loop (+ i 1))))
    (lambda () (with-output-to-file path void))))
