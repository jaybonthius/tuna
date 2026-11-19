#!tuna
;; Stands in for the web plugin, which this configuration lacks.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define (send-screen! client screen title) (void))

(define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define connected '())

(define (clients) connected)

(define (connect! c) (set! connected (append connected (list c))))

(define (disconnect! c) (set! connected (remq c connected)))

(define calls '())

(define (call-page! client name value)
  (set! calls (cons (list client name value) calls)))

(define (take-calls!)
  (let ([taken (reverse calls)])
    (set! calls '())
    taken))

(define (client-device client) (number->string (client-number client)))
