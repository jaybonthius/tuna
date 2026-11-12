#!tuna
;; Stands in for the web plugin, so that no server starts.
(define-record-type client (fields number))

(define-table input-handlers)
(define-table scripts)
(define-table stylesheets)
