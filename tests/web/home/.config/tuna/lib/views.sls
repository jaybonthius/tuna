#!tuna
;; Stands in for the views plugin the clipboard example imports.
(module (view-parameter)
  (define view-parameter (make-parameter #f)))

(define (current-view) (view-parameter))

(define (call-with-view view thunk)
  (parameterize ([view-parameter view]) (thunk)))
