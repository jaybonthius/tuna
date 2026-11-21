#!tuna
(import (modes))

(define-option column 70 fixnum? "Width of filled lines.")
(define-table keymap "Keys while fill mode is on.")
(modes:define-minor-mode mode
  "Whether typing past fill:column breaks the line."
  (lighter "Fill")
  (keymap keymap))
