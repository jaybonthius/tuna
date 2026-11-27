(library (command-line handled)
  (export take-arguments!)
  (import (chezscheme))

  ;; Chez creates this library once per process, so the arguments are
  ;; handed out once however often command-line is loaded again.
  (define taken? #f)

  (define (take-arguments!)
    (if taken?
        '()
        (begin
          (set! taken? #t)
          (command-line-arguments)))))
