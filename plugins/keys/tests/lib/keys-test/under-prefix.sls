#!tuna
(import (commands) (keys))

(commands:define-command (command) "Does nothing." (void))

(keys:bind! keys:global "C-c q x" command)
