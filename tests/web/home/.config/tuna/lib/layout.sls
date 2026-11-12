#!tuna
;; Stands in for the layout plugin the clipboard example imports.
(module (frame-parameter)
  (define frame-parameter (make-parameter #f)))

(define (frame client) (list 'frame client))

(define (current-frame) (frame-parameter))

(define (call-with-frame frame thunk)
  (parameterize ([frame-parameter frame]) (thunk)))
