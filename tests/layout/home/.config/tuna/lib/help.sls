#!tuna
;; Stands in for a help plugin, whose buffers the configuration displays
;; below the selected view.
(import (buffers))

(define (buffer? b) (string=? (buffers:name b) "*Help*"))

(define buffer (or (buffers:find "*Help*") (buffers:make "*Help*" "Help.\n")))
