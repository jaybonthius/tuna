(import (tuna) (modes) (hooks) (options) (tables) (modes-test text) (modes-test fill))

(tables:define-table notes-keymap)

(hooks:define-hook notes-hook)

(modes:define-major-mode notes-mode (parent modes-test/text:mode) (keymap notes-keymap) (hook notes-hook))

(modes:define-minor-mode spelling "Whether words are checked as they are typed.")

(putprop 'modes-test 'spelling spelling)

(tables:set! modes:lighters modes-test/text:mode "Tx")

(hooks:add! modes-test/text:mode-hook (lambda () (options:set-local! modes-test/fill:column 33)))
