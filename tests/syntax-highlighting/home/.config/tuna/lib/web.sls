#!tuna
(import (haml))

;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make, holding the last screen sent.
(define-record-type client (fields number (mutable screen) (mutable title)))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define-hook client-added)
(define-hook client-removed)

(define connected '())

(define (clients) connected)

(define (add-client! n)
  (let ([c (make-client n #f #f)])
    (set! connected (append connected (list c)))
    (client-added c)
    c))

(define (remove-client! c)
  (set! connected (remq c connected))
  (client-removed c))

(define (send-screen! client screen title)
  (client-screen-set! client (html->string screen))
  (client-title-set! client title))

(define current-client (make-thread-parameter #f))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

(define (call-page! client name value) (void))

