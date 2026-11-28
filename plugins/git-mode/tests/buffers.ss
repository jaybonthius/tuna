(import (tuna) (test) (test-user) (test-runner) (hooks) (options) (modes) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git)
        (git-mode) (git-status-test) (git-test repositories))

(define one (git-status-test:sample! "one"))

(define other
  (begin
    (git-test/repositories:git! "" "init" "-q" "-b" "main" "elsewhere/one")
    (git:find-repository (git-status-test:path "elsewhere/one"))))

(define rebuilt '())

(define (rebuild b) (set! rebuilt (cons (buffers:name b) rebuilt)))

(test "git-mode:buffer makes a repository's Git buffer of a mode once, named by prefix and repository, <2> for another repository of that name"
  (let ([b (git-mode:buffer one "test" git-mode:mode rebuild)])
    (check-equal? "*test: one*" (buffers:name b))
    (check (eq? b (git-mode:buffer one "other prefix" git-mode:mode rebuild)))
    (check-equal? "*test: one<2>*" (buffers:name (git-mode:buffer other "test" git-mode:mode rebuild)))
    (check-equal? (list one git-mode:mode git-mode:refresh #f)
                  (buffers:with-buffer b (list (git-mode:repository) (modes:major-mode b) (buffers:revert-function) (files:offer-save?))))))

(test "a refresh calls the buffer's rebuild procedure and leaves the whole buffer read-only"
  (let ([b (buffers:find "*test: one*")])
    (set! rebuilt '())
    (git-mode:refresh-repository one)
    (check-equal? '("*test: one*") rebuilt)
    (check-raises error? (buffers:insert! b 0 "x"))))

(test "git-mode:mode derives from ui:section-mode, lighter Git, and runs git-mode:mode-hook"
  (let* ([ran 0] [note (lambda () (set! ran (+ ran 1)))])
    (hooks:add! git-mode:mode-hook note)
    (git-mode:buffer (git-status-test:sample! "two") "test" git-mode:mode rebuild)
    (hooks:remove! git-mode:mode-hook note)
    (check-equal? 1 ran))
  (check-equal? '(git-mode:mode ui:section-mode modes:special) (modes:ancestry git-mode:mode))
  (check-equal? "Git" (modes:lighter git-mode:mode)))

(test "find-current-repository gives a Git buffer's repository, the one holding a file's folder, the one whose git folder holds a file, else #f; current-repository raises there"
  (let ([at (lambda (path) (buffers:with-buffer (files:visit (git-status-test:path path)) (git-mode:find-current-repository)))])
    (check-equal? (git:repository-root one) (git:repository-root (at "one/a.py")))
    (check-equal? (git:repository-root one) (git:repository-root (at "one/.git/COMMIT_EDITMSG")))
    (check-equal? (git:repository-root one) (git:repository-root (buffers:with-buffer (buffers:find "*test: one*") (git-mode:find-current-repository))))
    (mkdir (git-status-test:path "plain"))
    (check-equal? #f (at "plain/n.txt"))
    (check-raises (lambda (c) (and (error? c) (string=? "Not inside a Git repository" (condition-message c))))
      (buffers:with-buffer (buffers:find "n.txt") (git-mode:current-repository)))))

(test "confirm asks unless the action is in git-mode:no-confirm, and n raises Abort; confirmation names only known actions"
  (git-status-test:answer! #t #f)
  (git-mode:confirm (git-mode:confirmation discard) "Discard? ")
  (check-raises (lambda (c) (and (error? c) (string=? "Abort" (condition-message c))))
    (git-mode:confirm (git-mode:confirmation discard) "Discard? "))
  (check-equal? '("Discard? " "Discard? ") (git-status-test:take-asked!))
  (git-mode:confirm (git-mode:confirmation set-and-push) "Set? ")
  (check-equal? '() (git-status-test:take-asked!))
  (check-raises syntax-violation? (eval '(git-mode:confirmation sometimes) (interaction-environment))))

(test "a Git buffer keeps its repository, refresher and revert function when the plugin that made it unloads"
  (let* ([maker (make-owner '(git-buffer maker))]
         [b (call-as-owner maker (lambda () (git-mode:buffer other "made" git-mode:commands-mode rebuild)))])
    (unload-owner! maker)
    (check-equal? (list other git-mode:refresh)
                  (buffers:with-buffer b (list (git-mode:repository) (buffers:revert-function))))
    (set! rebuilt '())
    (git-mode:refresh-repository other)
    (check (member "*made: one*" rebuilt))))

(test "a refresh joined while the buffer is being rebuilt ends with the rebuild: when the rebuild raises, the joining task sees the raise"
  (let* ([runs 0] [paused #f]
         [rebuild (lambda (b)
                    (set! runs (+ runs 1))
                    (suspend (lambda (resume) (set! paused resume)))
                    (when (= runs 2) (error 'rebuild "refused")))]
         [b (git-mode:buffer one "raising" git-mode:commands-mode rebuild)]
         [ended '()]
         [refresh (lambda (name)
                    (spawn-task
                      (lambda (restore)
                        (set! ended (cons (cons name (guard (c [(error? c) (condition-message c)]) (git-mode:refresh-buffer b) 'returned))
                                          ended)))))])
    (refresh 'first)
    (test-runner:wait-until (lambda () paused))
    (refresh 'second)
    (test-user:settle)
    (let ([resume paused]) (set! paused #f) (resume void))
    (test-runner:wait-until (lambda () paused))
    (let ([resume paused]) (set! paused #f) (resume void))
    (test-runner:wait-until (lambda () (= 2 (length ended))))
    (check-equal? '((first . "refused") (second . "refused")) (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b)))) ended))
    (buffers:kill! b)))
