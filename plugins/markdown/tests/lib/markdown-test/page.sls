#!tuna
(import (buffers) (markdown))

(buffers:define-kind page (content nodes))

(define (make name text) (buffers:make name (apply page '() (markdown:blocks text))))
