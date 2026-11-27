#!tuna
(import (ui) (commands) (ui-test))

(commands:define-command (hi) "Says hi." (ui-test:say! 'hi))

(ui:define-button bye hi)
