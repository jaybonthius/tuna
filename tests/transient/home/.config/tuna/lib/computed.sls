#!tuna
(import (transient) (commands))

(transient:define-menu menu "A menu with a computed group.")

(define log '())

(commands:define-command (note [what 'none]) "Notes WHAT." (set! log (cons what log)))

(commands:define-command (show-menu) "Shows the menu." (transient:show! menu))

(transient:add-computed! menu "Computed"
  (lambda () (list (transient:command "p" "Original" note 'original))))
