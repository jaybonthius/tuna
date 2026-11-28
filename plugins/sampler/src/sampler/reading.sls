(library (sampler reading)
  (export reading-loop)
  (import (chezscheme) (timeseries))

  ;; The time is taken after the read, so it is the reading's own. What
  ;; the next reading needs of this one, such as the counters a rate is
  ;; taken from, is kept by the loop, so the libraries a reading uses keep
  ;; nothing.
  (define (reading-loop read input emit receive)
    (let loop ([kept #f])
      (receive)
      (let-values ([(next data) (read input kept)])
        (emit (cons (timeseries-now) data))
        (loop next)))))
