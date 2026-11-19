#!tuna
(import (ui) (buffers) (document) (layout) (commands))

(define list-buffer
  (or (buffers:find "*buffer list*") (buffers:make "*buffer list*" (ui:list '()))))

(define (buffer-row b) (ui:label (buffers:name b)))

(commands:define-command (list-buffers)
  "Shows the live buffers; RET or a click on one shows it."
  (ui:set-rows! list-buffer (document:token (buffers:document list-buffer) 0)
                (list->vector (buffers:all)) buffer-row layout:switch-to-buffer)
  (layout:switch-to-buffer list-buffer))
