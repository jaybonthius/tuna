#!tuna
;; Stands in for the editing plugin the clipboard example imports.
(import (views))

(define pastes '())

(define (paste text)
  (set! pastes (cons (list text (views:current-view)) pastes)))
