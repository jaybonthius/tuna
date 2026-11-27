#!tuna
(import (hooks) (tables))
;; Stands in for the web plugin, which this configuration lacks.
(define-record-type client (fields number))

(tables:define-table input-handlers)
(tables:define-table scripts)
(tables:define-table stylesheets)
(tables:define-table early-scripts)

(define (send-screen! client screen title) (void))

(hooks:define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define %connected '())

(define (clients) %connected)

(define (connect! c) (set! %connected (append %connected (list c))))

(define (disconnect! c) (set! %connected (remq c %connected)))

(define %calls '())

(define (call-page! client name value)
  (set! %calls (cons (list client name value) %calls)))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

(define (take-calls!)
  (let ([taken (reverse %calls)])
    (set! %calls '())
    taken))

