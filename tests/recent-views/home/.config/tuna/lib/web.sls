#!tuna
(import (haml) (hooks) (tables))

;; Stands in for the web plugin, so no server starts.
(define-record-type client (fields number (mutable screen) (mutable title)))

(tables:define-table input-handlers)
(tables:define-table scripts)
(tables:define-table stylesheets)
(tables:define-table early-scripts)

(hooks:define-hook client-added)
(hooks:define-hook client-removed)

(define %connected '())

(define (clients) %connected)

(define (add-client! n)
  (let ([c (make-client n #f #f)])
    (set! %connected (append %connected (list c)))
    (client-added c)
    c))

(define (remove-client! c)
  (set! %connected (remq c %connected))
  (client-removed c))

(define (send-screen! client screen title)
  (client-screen-set! client (html->string screen))
  (client-title-set! client title))

(define current-client (make-thread-parameter #f))

(define (call-page! client name value) (void))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

