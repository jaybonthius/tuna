#!tuna
(import (commands) (keys) (tables))

(tables:define-table prefix-map "Completion commands under one prefix.")

(commands:define-command (file) "Completes a file name." 'file)

(commands:define-command (dabbrev) "Completes a word from the buffers." 'dabbrev)

(keys:bind! prefix-map "f" file)
(keys:bind! prefix-map "d" dabbrev)
