#!tuna
(import (echo-area) (buffers) (document) (views) (commands))

(commands:define-command (what-line)
  "Shows the line point is on."
  (let ([view (views:current)])
    (echo-area:message! "Line ~a"
      (document:line (buffers:document (views:buffer view)) (views:point view)))))
