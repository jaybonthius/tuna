(import (tuna) (testing) (tuna plugins))
(define recent-commands '())

(use-plugin commands
  (config
    (add-hook! commands:after-command
      (lambda (command) (set! recent-commands (cons command recent-commands))))))

(commands:define-command (open-notes) "Opens the notes." 'notes)

(define (recent-names) (map commands:command-name recent-commands))

(import (console))
