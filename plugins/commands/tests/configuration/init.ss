(import (tuna) (hooks) (commands))

(use-plugin commands
  (config
    (hooks:add! commands:after-command
      (lambda (command) (putprop 'commands-test 'ran (cons (commands:command-name command) (getprop 'commands-test 'ran '())))))))

(commands:define-command (open-notes) "Opens the notes." 'notes)

(putprop 'commands-test 'first-notes open-notes)

(commands:define-command (open-notes) "Opens other notes." 'other)
