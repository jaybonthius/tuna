#!tuna
(import (modes) (modes-test text))

(modes:define-major-mode bad (keymap 1) (hook modes-test/text:mode-hook))
