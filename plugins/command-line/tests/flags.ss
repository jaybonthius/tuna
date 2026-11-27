(import (tuna) (test) (test-runner) (test-user) (options) (plugins) (command-line-test))

(define evaluated '())

(define (note! v) (set! evaluated (append evaluated (list v))))

(command-line-test:write-file! ".config/tuna/init.ss"
  "(import (tuna) (options) (command-line-test))\n(options:set! command-line-test:level 1)\n")

(plugins:load-configuration!)

(test "before the command line is handled, the configuration's setting is in effect"
  (check-equal? 1 (command-line-test:level)))

(command-line-arguments
  (list "--eval=(options:set! command-line-test:level 2)" "--eval=(note! (current-owner))" "--eval=(options:set! web:prot 1)"
        "--evl=1" "--eval=(warning 'flags \"take care\") (note! 'warned)" "--eval=(note! 'last) (note! 'and-after)"))

(define reported
  (test-runner:reports-during
    (lambda ()
      (load-module! '(command-line))
      (test-runner:wait-until (lambda () (= 4 (length evaluated))))
      (test-runner:wait-for-batch))))

(test "each --eval is evaluated in order, as the REPL's owner, every form of it"
  (check-equal? (list (plugins:repl-owner) 'warned 'last 'and-after) evaluated))

(test "a raise in an --eval is reported, and so is an unknown flag, and the arguments after each still run"
  (check-equal? 3 (length reported))
  (check (serious-condition? (car reported)))
  (check-equal? '("web:prot") (map symbol->string (condition-irritants (car reported))))
  (check (warning? (cadr reported)))
  (check-equal? "unknown flag --evl=1; the only flag is --eval=EXPR" (condition-message (cadr reported))))

(test "a warning in an --eval is reported, and the rest of that --eval runs"
  (check (warning? (caddr reported)))
  (check-equal? "take care" (condition-message (caddr reported))))

(test "an --eval's setting wins over the configuration's, and stays when the configuration is evaluated again"
  (check-equal? 2 (command-line-test:level))
  (check-equal? '() (test-runner:reports-during (lambda () (plugins:load-configuration!) (test-runner:wait-for-batch))))
  (check-equal? 2 (command-line-test:level)))

(test "a reload of the plugin evaluates no argument again"
  (check-equal? '() (test-runner:reports-during (lambda () (reload-modules! '((command-line))) (test-user:settle))))
  (check-equal? 4 (length evaluated)))
