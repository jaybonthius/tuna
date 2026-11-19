#!tuna
(import (buffers) (document))

(define (row-text node) (string-append (document:node-attribute node 'label) "\n"))
(define (tag-text node) (document:node-attribute node 'label))

(buffers:define-kind rows (content nodes))
(buffers:define-kind para)
(buffers:define-kind row (content atom) (text row-text))
(buffers:define-kind tag (content atom) (inline) (text tag-text))
