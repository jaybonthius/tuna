#!tuna
(import (buffers))

(define (refuse node edit) #f)

(buffers:define-kind doc (content nodes))
(buffers:define-kind para)
(buffers:define-kind reply (consent refuse))
(buffers:define-kind image (content atom) (inline))
(buffers:define-layer locked (read-only))
(buffers:define-layer marks (travels) (sticky after))
(buffers:define-kind heading)
(buffers:define-kind rule (content atom))
(buffers:define-kind grid (content nodes))
(buffers:define-kind row (content nodes))
(buffers:define-kind cell (isolating))
