#!tuna
(import (hooks) (tables))
;; Stands in for the web plugin, so that no server starts.
(define-record-type client (fields number))

(tables:define-table input-handlers)
(tables:define-table scripts)
(tables:define-table stylesheets)
(tables:define-table early-scripts)

(define (send-screen! client screen title) (void))

(hooks:define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define (clients) '())

(define (call-page! client name value) (void))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

