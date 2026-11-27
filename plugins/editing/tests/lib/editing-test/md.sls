#!tuna
(import (buffers))

(buffers:define-kind doc (content nodes))
(buffers:define-kind para)
(buffers:define-kind heading)
(buffers:define-kind image (content atom) (inline))
(buffers:define-kind rule (content atom))
(buffers:define-kind grid (content nodes))
(buffers:define-kind row (content nodes))
(buffers:define-kind cell (isolating))
(buffers:define-layer locked (read-only))
