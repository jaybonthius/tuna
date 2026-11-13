#!tuna
(import (buffers))

(define (status-buffer? b) (string=? (buffers:name b) "magit: tuna"))
