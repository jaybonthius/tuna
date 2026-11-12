#!tuna
;; Kinds and a layer type that carry keymaps, as values: views only
;; gathers them.
(import (buffers))

(buffers:define-kind box (content nodes) (keymap 'box-keys))
(buffers:define-kind field (keymap 'field-keys))
(buffers:define-layer links (keymap 'link-keys))
(buffers:define-layer plain)
