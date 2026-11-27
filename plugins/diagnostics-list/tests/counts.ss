(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (keys) (buffers) (views) (layout) (files) (tables) (status-line)
        (diagnostics) (diagnostics-list) (lists))

(options:set! diagnostics:check-delay #f)

(keys:bind! keys:global "C-c c" diagnostics:check)

(mkdir lists:root)

(define notes (files:visit (lists:write-file! "notes.txt" "alpha beta gamma\ndelta epsilon\nzeta eta\n")))

(layout:switch-to-buffer notes)

(define source (diagnostics:make-source))

(lists:mode! notes #t)

(diagnostics:report! source notes
  (list (lists:mark notes "beta" (diagnostics:severity warning) "vague")
        (lists:mark notes "delta" (diagnostics:severity error) "wrong")
        (lists:mark notes "zeta" (diagnostics:severity hint) "short")))

(test "the counts segment, placed in the status line, shows errors, warnings, and infos with hints, each in its face with its number in data-count"
  (check (status-line:place? (tables:ref status-line:segments diagnostics-list:counts #f)))
  (check-equal? "1 1 1" (lists:counts))
  (check-equal? '(("error" "1") ("warning" "1") ("success" "1")) (lists:count-faces)))

(test "Wait shows while a check runs"
  (let ([held #f])
    (define (waiting b) (suspend (lambda (resume) (set! held resume))) '())
    (buffers:with-buffer notes (hooks:add-local! diagnostics:checkers waiting))
    (test-user:press! "C-c c")
    (test-runner:wait-until (lambda () held))
    (check-equal? "1 1 1 Wait" (lists:counts))
    (held void)
    (test-runner:wait-until (lambda () (not (diagnostics:checking? notes))))
    (check-equal? "1 1 1" (lists:counts))
    (buffers:with-buffer notes (hooks:remove-local! diagnostics:checkers waiting))))

(test "! shows after a checker raised"
  (define (broken b) (error 'broken "no linter"))
  (buffers:with-buffer notes (hooks:add-local! diagnostics:checkers broken))
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (test-user:press! "C-c c")
    (test-runner:wait-until (lambda () (pair? reported)))
    (advice-remove! report keep)
    (check-equal? '("no linter") (map condition-message reported)))
  (check-equal? "1 1 1 !" (lists:counts)))

(test "nothing shows where the mode is off"
  (lists:mode! notes #f)
  (check-equal? #f (lists:counts))
  (lists:mode! notes #t))

(test "a click on the segment shows the buffer's list"
  (test-user:settle)
  (test-user:click-element! (lists:counts-element))
  (check (pair? (views:showing (lists:list-buffer "notes.txt")))))
