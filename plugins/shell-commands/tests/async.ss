(import (tuna) (test) (test-runner) (test-user) (options) (buffers) (document) (views) (layout) (modes) (ask) (runs)
        (shell-commands) (shell-commands-test))

(define run shell-commands-test:run)

(define saved 0)

(advice-add! shell-commands:save-buffers (lambda (next) (set! saved (+ saved 1))))

(define asked '())

(options:set! ask:yes-or-no-reader (lambda (q) (set! asked (cons q asked)) #t))

(define first #f)

(test "M-& runs a line as the user's run in *Async Shell Command*, shown and not selected, and saves no buffer"
  (test-user:press! "M-&")
  (test-user:type! "echo first; until [ -e go ]; do sleep 0.05; done")
  (test-user:press! "RET")
  (set! first (buffers:find "*Async Shell Command*"))
  (test-runner:wait-until (lambda () (equal? "first\n" (shell-commands-test:output first))))
  (check-equal? #f (runs:status first))
  (check (member "*Async Shell Command*" (shell-commands-test:shown)))
  (check-equal? #f (eq? first (views:buffer (layout:selected-view))))
  (check-equal? 0 saved))

(test "M-&'s buffer is in shell-command-mode, whose views follow the output, as Emacs's shell-command-mode does; a build's start at the top"
  (check-equal? (list (- (document:length (buffers:document first)) 1)) (map views:point (views:showing first)))
  (check-equal? shell-commands:shell-command-mode (modes:major-mode first))
  (check (modes:derived? shell-commands:shell-command-mode runs:mode))
  (check-equal? #f (runs:follow-output?)))

(test "with a run going there, M-& asks before it runs in a new buffer"
  (run shell-commands:async-shell-command "echo second")
  (let ([second (buffers:find "*Async Shell Command*<2>")])
    (check-equal? 0 (shell-commands-test:ended second))
    (check-equal? (list '("A command is running in the default buffer. Use a new buffer? ") "second" #f)
                  (list asked (shell-commands-test:output second) (runs:status first)))))

(test "on no, M-& raises and starts nothing"
  (options:set! ask:yes-or-no-reader (lambda (q) #f))
  (check-equal? '((shell-commands:async-shell-command "a command is running in the default buffer"))
                (test-runner:shown-reports-during (lambda () (run shell-commands:async-shell-command "echo refused"))))
  (check-equal? #f (buffers:find "*Async Shell Command*<3>"))
  (options:set! ask:yes-or-no-reader (lambda (q) (set! asked (cons q asked)) #t)))

(test "an override of async-shell-command-buffer chooses otherwise: this one renames the busy run's buffer and reuses the name"
  (advice-add! shell-commands:async-shell-command-buffer
    (lambda (next)
      (let ([busy (buffers:find "*Async Shell Command*")])
        (when (and busy (runs:run-buffer? busy) (not (runs:status busy)))
          (buffers:rename! busy (buffers:free-name "*Async Shell Command*")))
        "*Async Shell Command*")))
  (run shell-commands:async-shell-command "echo third")
  (let ([third (buffers:find "*Async Shell Command*")])
    (check-equal? 0 (shell-commands-test:ended third))
    (check-equal? '("third" "*Async Shell Command*<3>" #f 1)
                  (list (shell-commands-test:output third) (buffers:name first) (runs:status first) (length asked))))
  (shell-commands-test:touch! "go")
  (check-equal? 0 (shell-commands-test:ended first))
  (check-equal? "first" (shell-commands-test:output first)))
