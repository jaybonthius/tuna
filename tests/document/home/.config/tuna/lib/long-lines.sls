#!tuna
(import (jobs) (buffers))

(jobs:define-worker (long-lines version emit)
  (import (document))
  (let* ([doc (cdr version)]
         [size (document:length doc)]
         [last (document:line doc size)])
    (do ([line 1 (+ line 1)]) ((> line last))
      (let ([start (document:line-start doc line)]
            [end (if (= line last) size (document:line-start doc (+ line 1)))])
        (when (> (- end start) 100)
          (emit (list (car version) start end)))))))

(define (check! buffer)
  (jobs:start long-lines (cons (buffers:version buffer) (buffers:document buffer))
              (lambda (result) (display result))))
