#!tuna
(import (ui) (commands))

(commands:define-command (hi) "Hi." (void))

(ui:define-button 3 hi)
