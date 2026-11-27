#!tuna
(import (buffers))

(buffers:define-kind doc (content nodes))
(buffers:define-kind heading)
(buffers:define-kind para)
(buffers:define-kind item)
(buffers:define-kind code)
(buffers:define-kind link (inline) (sticky neither))
(buffers:define-kind image (content atom) (inline))
