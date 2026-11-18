#!tuna
(import (keys) (commands) (transient))

(define-table keymap "Python mode's keys.")

(define-table shell-keymap "Python's shell keys.")

(commands:define-command (send-buffer) "Sends the buffer to Python." (void))

(commands:define-command (switch-to-shell) "Shows Python's shell." (void))

(commands:define-command (python-keys)
  "Shows Python mode's keys."
  (transient:show! keymap))

(keys:bind! keymap "C-c C-c" send-buffer)
(keys:bind! keymap "C-c C-z" switch-to-shell)
(keys:bind! keymap "C-c C-s" shell-keymap)
