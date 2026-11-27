#!tuna
(import (modes) (modes-test text))

(modes:define-major-mode bad (hook modes-test/text:mode-hook))
