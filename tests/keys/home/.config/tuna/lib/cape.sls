#!tuna
;; Stands in for a completion plugin with a prefix keymap.
(import (commands) (keys))

(define-table prefix-map "Completion commands under one prefix.")

(commands:define-command (file) "Completes a file name." 'cape-file)

(commands:define-command (dabbrev) "Completes a word from the buffers." 'cape-dabbrev)

(keys:bind! prefix-map "f" file)
(keys:bind! prefix-map "d" dabbrev)
