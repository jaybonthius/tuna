#!tuna
(import (buffers) (commands) (ask))

(commands:define-command (kill-scratch)
  "Kills *scratch*, asking first."
  (let ([b (buffers:find "*scratch*")])
    (when (and b (ask:y-or-n? "Kill *scratch*? "))
      (buffers:kill! b))))

(commands:define-command (rename-scratch [name (ask:line "Rename *scratch* to: ")])
  "Renames *scratch* to NAME."
  (let ([b (buffers:find "*scratch*")])
    (when b (buffers:rename! b name))))
