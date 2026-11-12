#!tuna
(import (buffers) (views) (haml))

(define (draw-section node view)
  (haml (:section.magit-section
          (views:draw-children view node
            (lambda (child html) (haml (:div.child html)))))))

(buffers:define-kind section (content nodes) (draw draw-section))
