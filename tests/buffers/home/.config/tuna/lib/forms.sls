#!tuna
(import (buffers) (document) (views) (haml))

(define (one-line? node edit)
  (not (memv #\newline (string->list (document:text (buffers:edit-inserted edit))))))

(define (draw-field node view)
  (haml (:span.field (views:draw-children view node))))

(buffers:define-kind field
  (inline)
  (consent one-line?)
  (draw draw-field))
