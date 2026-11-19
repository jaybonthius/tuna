#!tuna
(import (buffers) (document))

(define (badge-text node) (document:node-attribute node 'label))

(buffers:define-kind doc (content nodes))
(buffers:define-kind para)
(buffers:define-kind link (inline) (sticky neither))
(buffers:define-kind image (content atom) (inline))
(buffers:define-kind badge (content atom) (inline) (text badge-text))
