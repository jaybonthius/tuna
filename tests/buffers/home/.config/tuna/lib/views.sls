#!tuna
;; Stands in for the views plugin, which this configuration lacks.
(import (document))

(define (draw-children view node) (list 'children-of (document:node-kind node)))
