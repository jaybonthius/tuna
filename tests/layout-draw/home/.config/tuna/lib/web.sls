#!tuna
(import (haml))

;; Stands in for the web plugin, so no server starts.
(define-record-type client (fields name (mutable given) (mutable title)))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define-hook client-added)
(define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define connected '())

(define (clients) connected)

(define (connect! name)
  (let ([c (make-client name '() #f)])
    (set! connected (append connected (list c)))
    c))

(define (disconnect! c) (set! connected (remq c connected)))

(define (send-screen! client screen title)
  (client-given-set! client (cons (html->string screen) (client-given client)))
  (client-title-set! client title))

(define (given! client)
  (let ([g (reverse (client-given client))])
    (client-given-set! client '())
    g))

(define (call-page! client name value) (void))

(define (client-device client) (symbol->string (client-name client)))

;; Layout imports web, so this advice is beneath layout's.
(define batches 0)

(define (count-batch!) (set! batches (+ batches 1)))

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (count-batch!)))
