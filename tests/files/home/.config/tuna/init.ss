(import (tuna) (tuna plugins) (document))
(use-plugin files
  (config
    (set-option! files:require-final-newline #t)))
(import (disk-checks))

(define (text b) (document:text (buffers:document b)))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(import (console))
