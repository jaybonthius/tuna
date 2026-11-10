#!tuna
;; The stop is seen in the worker's own thread, where it writes the file
;; a test can wait for.
(define-worker (count-slowly path)
  (dynamic-wind
    void
    (lambda ()
      (let loop ([i 0])
        (emit i)
        (sleep (make-time 'time-duration 10000000 0))
        (loop (+ i 1))))
    (lambda () (with-output-to-file path void))))
