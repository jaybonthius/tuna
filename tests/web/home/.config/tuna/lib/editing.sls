#!tuna
;; Stands in for the editing plugin the clipboard example imports.
(import (layout))

(define pastes '())

(define (paste text)
  (set! pastes (cons (list text (layout:current-frame)) pastes)))
