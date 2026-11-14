#!tuna
(import (minibuffer) (buffers) (views) (commands))

(define-saved rename-history '() list?)

(commands:define-command (rename-buffer [name (minibuffer:read "Rename buffer to: " rename-history)])
  "Renames the current buffer to NAME."
  (buffers:rename! (views:buffer (views:current)) name))
