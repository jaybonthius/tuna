(import (tuna) (test) (test-user) (hooks) (options) (timers) (buffers) (document) (views) (layout) (layout-split) (editing) (files)
        (ui) (git) (git-mode) (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define (listed? name) (and (member name (git-status-test:status)) #t))

(define events '())

(hooks:add! git-mode:before-refresh (lambda (r) (set! events (cons (list 'before (git:repository-name r)) events))))
(hooks:add! git-mode:after-refresh (lambda (r) (set! events (cons (list 'after (git:repository-name r)) events))))

(define (take-events!) (let ([e (reverse events)]) (set! events '()) e))

(test "a file changed outside Tuna changes nothing until a refresh"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(untracked . #f)))
  (git-test/repositories:write-file! "repo/outside.txt" "outside\n")
  ;; The claim is that nothing happens, so only a pause can show it.
  (timers:sleep 0.2)
  (check (not (listed? "outside.txt"))))

(test "g refreshes through buffers:revert-function, between before-refresh and after-refresh; point stays on its section"
  (take-events!)
  (git-status-test:go-to-section! '(file . "b.txt") '(unstaged . #f))
  (git-status-test:press! "g")
  (check-equal? '(((before "repo") (after "repo")) "modified   b.txt" #t)
                (list (take-events!) (git-status-test:point-line) (listed? "outside.txt")))
  (check (eq? git-mode:refresh (buffers:with-buffer (git-status-test:status-buffer) (buffers:revert-function)))))

(test "a command of the repository refreshes every Git buffer of it"
  (git-status-test:press! "$")
  (let ([log (views:buffer (git-status-test:view))])
    (git-status-test:press! "C-x o")
    (take-events!)
    (git-status-test:go-to-section! '(file . "outside.txt") '(untracked . #f))
    (git-status-test:press! "s")
    (check-equal? '(((before "repo") (after "repo")) " M a.py\nMM b.txt\n D gone.txt\n M long.txt\nA  outside.txt\n?? new.txt\n")
                  (list (take-events!) (git-status-test:short "repo")))
    (check-equal? "  0 git … add --pathspec-from-file=- --pathspec-file-nul\n" (document:text (buffers:document log)))))

(test "G refreshes every Git buffer of the repository"
  (take-events!)
  (git-status-test:press! "G")
  (check-equal? '((before "repo") (after "repo")) (take-events!)))

(test "keys typed while git runs act in order, each on the buffer the one before left: s s s stages three files in turn"
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (git-status-test:press! "s s s")
  (check-equal? '("M  a.py\nM  b.txt\nD  gone.txt\n M long.txt\nA  outside.txt\n?? new.txt\n" "modified   long.txt")
                (list (git-status-test:short "repo") (git-status-test:point-line))))

(test "git-mode:save-repository-buffers save saves without asking, and never leaves the buffer"
  (let ([c (files:visit (git-status-test:path "repo/a.py"))])
    (buffers:insert! c 1 "again\n")
    (options:set! git-mode:save-repository-buffers (git-mode:saving save))
    (git-status-test:press! "g")
    (check-equal? '(() #f) (list (git-status-test:take-asked!) (buffers:modified? c)))
    (buffers:insert! c 1 "never\n")
    (options:set! git-mode:save-repository-buffers (git-mode:saving never))
    (git-status-test:press! "g")
    (check-equal? '(() #t) (list (git-status-test:take-asked!) (buffers:modified? c)))
    (options:unset! git-mode:save-repository-buffers)
    (files:save-buffer c)
    (check-raises syntax-violation? (eval '(git-mode:saving sometimes) (interaction-environment)))))

(test "a command that changes files reverts the unmodified buffers visiting them, unless git-mode:revert-buffers? is #f"
  (let ([a (buffers:find "a.py")] [ending (lambda (b) (let ([t (document:text (buffers:document b))]) (substring t (- (string-length t) 5) (string-length t))))])
    (git-test/repositories:write-file! "repo/a.py" "one\nmore\n")
    (options:set! git-mode:revert-buffers? #f)
    (git-status-test:press! "g")
    (check-equal? "even\n" (substring (ending a) 0 5))
    (options:unset! git-mode:revert-buffers?)
    (git-status-test:press! "g")
    (check-equal? "more\n" (ending a))))
