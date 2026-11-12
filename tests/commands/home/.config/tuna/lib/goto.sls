#!tuna
(import (commands) (views) (buffers) (document))

(commands:define-command (goto-line [line (commands:prefix-number)])
  "Moves point to the start of line LINE."
  (let* ([view (views:current)]
         [doc (buffers:document (views:buffer view))])
    (views:set-point! view (document:line-start doc line))))
