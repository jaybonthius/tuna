#!tuna
;; Stands in for the kill-ring plugin the clipboard example imports.
(define-hook after-push "Called with each entry pushed.")

(define (text entry) (car entry))

(define (push! text) (after-push (list text)))
