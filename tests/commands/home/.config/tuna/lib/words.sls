#!tuna
(import (commands) (views) (editing))

(commands:define-command (forward-word [n (commands:prefix-number)])
  "Moves point forward N words."
  (let ([view (views:current)])
    (views:set-point! view
      (editing:forward-word-position (views:buffer view) (views:point view) n))))
