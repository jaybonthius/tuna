#!tuna
;; Stands in for the web plugin, so no server starts: clients are records
;; the tests make, each a device of its own unless given one.
(define-record-type client
  (fields number device)
  (protocol
    (lambda (new)
      (case-lambda
        [(number) (new number (number->string number))]
        [(number device) (new number device)]))))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
(define-table early-scripts)

(define (send-screen! client screen title) (void))

(define-hook client-removed)

(define current-client (make-thread-parameter #f))

(define (clients) '())

(define (call-page! client name value) (void))

;; No page answers a stand-in client.
(define (ask-page client name value) #f)
