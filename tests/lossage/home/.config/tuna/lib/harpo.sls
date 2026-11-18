#!tuna
(import (commands))

(commands:define-command (honk)
  "Does nothing."
  (void))

(commands:define-command (honk-twice)
  "Runs honk twice."
  (commands:run honk)
  (commands:run honk))
