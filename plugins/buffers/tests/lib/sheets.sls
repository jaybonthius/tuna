#!tuna
(import (buffers))

(buffers:define-kind grid (content nodes))
(buffers:define-kind row (content nodes))
(buffers:define-kind cell (isolating))
(buffers:define-kind box (content nodes) (isolating))
(buffers:define-kind rule (content atom))
