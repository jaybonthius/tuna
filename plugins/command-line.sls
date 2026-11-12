#!tuna
(import (tuna eval))

;; The process id and the command line handled, so a reload in the same
;; process evaluates nothing again.
(define-saved %arguments '() list?)

(post!
  (lambda ()
    (let ([handled (cons (get-process-id) (command-line-arguments))])
      (unless (equal? (%arguments) handled)
        (for-each
          (lambda (argument)
            (cond
              [(and (fx>= (string-length argument) 7) (string=? (substring argument 0 7) "--eval="))
               (guard (c [(not (quit-condition? c)) (report c)])
                 (eval-text (substring argument 7 (string-length argument))))]
              [(and (fx>= (string-length argument) 2) (string=? (substring argument 0 2) "--"))
               (report (condition (make-warning)
                         (make-message-condition (format "unknown flag ~a; the only flag is --eval=EXPR" argument))))]))
          (cdr handled))
        (set-saved! %arguments handled)))))
