#!tuna
(import (keys) (tables) (test-user))

(tables:define-table keymap "Pushed while the module is loaded.")

(keys:push-keymap! (test-user:client) keymap (lambda (found command) #t))
