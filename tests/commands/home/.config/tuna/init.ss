(import (hooks) (tables) (timers) (plugins))
(import (tuna) (testing))
(define recent-commands '())

(use-plugin commands
  (config
    (hooks:add! commands:after-command
      (lambda (command) (set! recent-commands (cons command recent-commands))))))

(commands:define-command (open-notes) "Opens the notes." 'notes)

(define (recent-names) (map commands:command-name recent-commands))

(import (console))
