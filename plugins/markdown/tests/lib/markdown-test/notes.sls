#!tuna
(import (buffers) (document) (markdown))

(define (draw-note node view)
  (markdown:html (document:node-attribute node 'text)))

(buffers:define-kind note (content atom) (draw draw-note))
