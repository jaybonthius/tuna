(import (tuna) (test) (test-runner) (options) (hooks) (buffers) (terminal))

(define marks '())

(hooks:add! terminal:semantic-prompt (lambda (t mark code command) (set! marks (cons (list mark code command) marks))))

(define (commands-marked) (filter (lambda (m) (memq (car m) '(command-start command-end))) (reverse marks)))

(define (runs-integrated shell environment)
  (set! marks '())
  (options:set! terminal:shell (list shell))
  (options:set! terminal:environment environment)
  (let ([t (terminal:start #f)] [line (string-append "cd /tmp; echo " shell "-done")])
    (test-runner:wait-until (lambda () (assq 'input marks)))
    (terminal:send! t (string-append line "\r"))
    (test-runner:wait-until (lambda () (and (assq 'command-end marks) (equal? "/tmp" (terminal:directory t)))))
    (check-equal? "/tmp" (terminal:directory t))
    (check-equal? (list (list 'command-start #f line) '(command-end 0 #f)) (commands-marked))
    (buffers:kill! t)))

(test "zsh starts with the plugin's integration: it reports its folder and marks its commands"
  (runs-integrated "zsh" '(("PS1" . "%% "))))

(test "fish starts with the plugin's integration: it reports its folder and marks its commands"
  (runs-integrated "fish" '()))
