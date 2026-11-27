(import (tuna) (test) (commands) (commands-test demo))

(define (ran) (getprop 'commands-test 'ran '()))

(test "the configuration defines a command under its id, and defining it again replaces it"
  (let ([notes (commands:command-named 'open-notes)])
    (check (commands:command? notes))
    (check-equal? 'open-notes (commands:command-name notes))
    (check-equal? 'other (commands:run notes))
    (check-equal? #f (commands:command? (getprop 'commands-test 'first-notes)))))

(test "the configuration's after-command entry sees each outermost run"
  (commands:run commands-test/demo:hello)
  (check-equal? '(commands-test/demo:hello open-notes) (ran)))

(test "reloading commands keeps the configuration's commands and hook entries, and the modules that define commands"
  (reload-modules! '((commands)))
  (check (commands:command? (commands:command-named 'open-notes)))
  (check (commands:command? commands-test/demo:hello))
  (check-equal? '(open-notes commands-test/demo:hello commands-test/demo:add commands-test/demo:ordered commands-test/demo:slow
                  commands-test/demo:which-task commands-test/demo:pair-of commands-test/demo:%hidden)
                (commands:command-names))
  (check-equal? "Hello, you!" (commands:run commands-test/demo:hello))
  (check-equal? 'commands-test/demo:hello (car (ran))))
