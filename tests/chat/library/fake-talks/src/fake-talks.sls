#!tuna
(import (hooks))
;; Conversations held in memory, which outlive a reload of chat and of
;; the sources on them, as an agent's model does.

(hooks:define-hook changed "Called with a talk whenever it changes.")

(define-record-type talk
  (fields kind directory (mutable session) (mutable items) (mutable questions) (mutable working?) (mutable sent)
          (mutable answered)))

(define %talks '())

(define %started 0)

(define (start kind directory)
  (set! %started (+ %started 1))
  (let ([t (make-talk kind directory (string-append (symbol->string kind) "-" (number->string %started)) '() '() #f '()
                      '())])
    (set! %talks (append %talks (list t)))
    (changed t)
    t))

(define (of-kind kind) (lambda (v) (and (talk? v) (eq? (talk-kind v) kind))))

(define (live kind) (lambda () (filter (of-kind kind) %talks)))

(define (reply! t text)
  (talk-items-set! t (append (talk-items t) (list (vector (length (talk-items t)) 'reply text))))
  (changed t))

(define (ask! t id title answers)
  (talk-questions-set! t (append (talk-questions t) (list (list id title answers))))
  (changed t))

(define (working! t working?)
  (talk-working?-set! t working?)
  (changed t))

(define (end! t)
  (set! %talks (remq t %talks))
  (changed t))
