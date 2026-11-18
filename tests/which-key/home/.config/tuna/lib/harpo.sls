#!tuna
(import (commands) (keys))

(define-table keymap "Harpo's horn.")

(commands:define-command (honk)
  "Does nothing."
  (void))

(commands:define-command (squeak)
  "Does nothing either."
  (void))

(keys:bind! keymap "h" honk)
(keys:bind! keymap "s" squeak)
