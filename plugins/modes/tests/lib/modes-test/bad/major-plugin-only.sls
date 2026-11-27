#!tuna
(import (modes) (modes-test text))

(modes:define-major-mode bad (keymap modes-test/text:keymap) (hook modes-test/text:mode-hook) (plugin-only 'yes))
