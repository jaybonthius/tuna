#!tuna
(import (tables))
(tables:define-table keymap)
(tables:set! keymap "M-." 'geiser-edit-symbol-at-point)
