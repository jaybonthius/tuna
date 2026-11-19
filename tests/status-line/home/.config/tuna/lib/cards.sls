#!tuna
(import (buffers) (document))

(define (row-text node) (string-append (document:node-attribute node 'label) "\n"))

(buffers:define-kind rows (content nodes))
(buffers:define-kind row (content atom) (text row-text))
(buffers:define-kind blank (content atom))
