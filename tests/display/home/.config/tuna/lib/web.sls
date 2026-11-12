#!tuna
(import (haml))

;; Stands in for the web plugin, so no server starts.
(define-record-type client (fields name (mutable given)))

(define connected '())

(define (clients) connected)

(define (connect! name)
  (let ([c (make-client name '())])
    (set! connected (append connected (list c)))
    c))

(define (disconnect! c) (set! connected (remq c connected)))

(define (send-screen! client screen)
  (client-given-set! client (cons (html->string screen) (client-given client))))

(define (given! client)
  (let ([g (reverse (client-given client))])
    (client-given-set! client '())
    g))

;; Display imports web, so this advice is beneath display's.
(define batches 0)

(define (count-batch!) (set! batches (+ batches 1)))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (count-batch!)))
