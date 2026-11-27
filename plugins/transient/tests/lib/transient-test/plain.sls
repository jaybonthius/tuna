#!tuna
(import (keys) (commands) (tables))

(tables:define-table keymap "Plain keys.")

(commands:define-command (hello) "Says hello." (void))

(keys:bind! keymap "h" hello)
