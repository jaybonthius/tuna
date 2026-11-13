#!tuna
(import (modes))

(define-option column 70 fixnum? "Width of filled lines.")
(define-option mode #f boolean? "Whether typing past fill:column breaks the line.")
(define-table keymap "Keys while fill mode is on.")
(table-set! modes:minor-modes mode 0)
(table-set! modes:lighters mode "Fill")
(table-set! modes:keymaps mode keymap)
