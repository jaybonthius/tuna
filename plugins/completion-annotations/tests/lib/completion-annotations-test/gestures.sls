#!tuna
(import (commands) (keys))

(commands:define-command (wave)
  "Waves a hand.
Only the first line of this shows beside the command."
  (void))

(commands:define-command (nod)
  "Nods."
  (void))

(keys:bind! keys:global "C-c w" wave)
