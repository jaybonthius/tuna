#!tuna
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define (send-screen! client screen title) (void))

(define-hook client-added)
(define-hook client-removed)

(define connected '())

(define (clients) connected)

(define (add-client! n)
  (let ([c (make-client n)])
    (set! connected (append connected (list c)))
    (client-added c)
    c))

(define current-client (make-thread-parameter #f))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)

(define (call-page! client name value) (void))

(define (remove-client! c)
  (set! connected (remq c connected))
  (client-removed c))
