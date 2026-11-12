#!tuna
;; A kind of its own module, so a test can unload it.
(import (buffers) (views) (haml))

(define (draw-item node view) (haml (:li (views:draw-children view node))))

(buffers:define-kind bulleted (content nodes))
(buffers:define-kind item (draw draw-item))
