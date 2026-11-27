#!tuna
(import (modes) (commands) (keys) (tables) (hooks))

(tables:define-table keymap "Keys in snake buffers.")

(hooks:define-hook mode-hook "Called in each buffer that turns on snake mode.")

(modes:define-major-mode mode (lighter "Snake") (keymap keymap) (hook mode-hook))

(commands:define-command (run) "Runs the snake." (void))

(commands:define-command (anywhere) "Runs anywhere." (void))

(tables:set! commands:command-modes run (list mode))
(keys:bind! keymap "C-c C-c" anywhere)
