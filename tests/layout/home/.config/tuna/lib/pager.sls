#!tuna
;; Stands in for a plugin whose buffers the configuration displays below
;; the selected view.
(import (buffers))

(define (buffer? b) (string=? (buffers:name b) "*Pager*"))

(define buffer (or (buffers:find "*Pager*") (buffers:make "*Pager*" "Pager.\n")))
