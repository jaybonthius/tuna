(import (tuna) (test) (test-runner) (hooks) (options) (processes) (git) (git-test repositories))

(define (log-lines repository)
  (map (lambda (c) (list (git:command-exit c) (git:command-arguments c))) (git:commands repository)))

(define (failure thunk)
  (guard (c [(git:failed-condition? c) (git:failure-summary c)]) (thunk) 'no-failure))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (let ([result (thunk)])
      (advice-remove! report keep)
      (values result (reverse reported)))))

(git-test/repositories:sample! "repo")

(define repo (git:find-repository (git-test/repositories:path "repo")))

(test "a query returns git's standard output as bytes, writes its input's bytes, and is not logged"
  (check-equal? "main\n" (utf8->string (git:query repo '("rev-parse" "--abbrev-ref" "HEAD"))))
  (check-equal? "6f83395d973c448cdb70a7b21f7fc8018797acf6\n"
    (utf8->string (git:query repo '("hash-object" "--stdin") (bytevector 99 97 102 233 10))))
  (check-equal? '() (git:commands repo)))

(test "a command is logged with its arguments, less the global ones, and its exit status, and git:command-ended follows it"
  (let* ([ended '()] [note (lambda (r c) (set! ended (cons (git:command-arguments c) ended)))])
    (hooks:add! git:command-ended note)
    (check-equal? #vu8() (git:run repo '("tag" "v1")))
    (hooks:remove! git:command-ended note)
    (check-equal? '((0 ("tag" "v1"))) (log-lines repo))
    (check-equal? '(("tag" "v1")) ended)))

(test "a failure raises git:&failed, whose message is the last fatal: or error: line without that word, and is logged"
  (check-equal? "Could not read from remote repository." (failure (lambda () (git:run repo '("fetch" "nowhere")))))
  (check-equal? '(128 ("fetch" "nowhere")) (car (reverse (log-lines repo))))
  (let ([c (guard (c [(git:failed-condition? c) c]) (git:run repo '("checkout" "no-such-branch")))])
    (check-equal? "pathspec 'no-such-branch' did not match any file(s) known to git" (git:failure-summary c))
    (check-equal? (git:failure-summary c) (condition-message c))
    (check-equal? 1 (git:command-exit (git:failure-command c)))
    (check-equal? "error: pathspec 'no-such-branch' did not match any file(s) known to git\n"
      (git:command-output (git:failure-command c))))
  (check-equal? "Needed a single revision" (failure (lambda () (git:query repo '("rev-parse" "--verify" "nothing"))))))

(test "a query's failure names an entry that is not in the log"
  (let ([c (guard (c [(git:failed-condition? c) c]) (git:query repo '("cat-file" "-p" "nothing")))])
    (check (git:command? (git:failure-command c)))
    (check (not (memq (git:failure-command c) (git:commands repo))))))

(test "a repository's commands run one at a time in the order called, each queued before its call pauses"
  (let* ([updates '()]
         [note (lambda (r c) (set! updates (cons (list (car (git:command-arguments c)) (git:command-exit c)) updates)))])
    (hooks:add! git:command-updated note)
    (let* ([first-task (spawn-task (lambda (restore) (git:run repo '("tag" "v2"))))]
           [second-task (spawn-task (lambda (restore) (git:run repo '("tag" "v3"))))])
      (check-equal? #vu8() (test-runner:join first-task))
      (check-equal? #vu8() (test-runner:join second-task)))
    (hooks:remove! git:command-updated note)
    (check-equal? '(("tag" #f) ("tag" #f)) (list-head (reverse updates) 2))
    (check-equal? "v1\nv2\nv3\n" (utf8->string (git:query repo '("tag"))))))

(test "git:start returns the command at once; when it ends on-end runs with it, then git:command-ended"
  (let* ([order '()] [note (lambda (r c) (set! order (cons 'hook order)))])
    (hooks:add! git:command-ended note)
    (let ([started (git:start repo '("tag" "v4") (lambda (c) (set! order (cons 'on-end order))))])
      (check (git:command? started))
      (test-runner:wait-until (lambda () (git:command-exit started)))
      (hooks:remove! git:command-ended note)
      (check-equal? 0 (git:command-exit started))
      (check-equal? '(on-end hook) (reverse order)))))

(test "git:start adds an environment clause to git's, and raises for any other clause"
  (let ([shown (git:start repo '("var" "GIT_EDITOR") (lambda (c) (void))
                 (processes:options [environment '(("GIT_EDITOR" . "my-editor"))]))])
    (test-runner:wait-until (lambda () (git:command-exit shown)))
    (check-equal? "my-editor\n" (git:command-output shown)))
  (check-equal? "git:start takes an environment only"
    (guard (c [(assertion-violation? c) (condition-message c)])
      (git:start repo '("status") (lambda (c) (void)) (processes:options [directory "/"])))))

(test "by default git fails at once rather than ask for a password"
  (check-equal? "0" (cdr (assoc "GIT_TERMINAL_PROMPT" (git:environment)))))

(test "git:stop! ends a running command, which fails with the signal's status, and raises for one that has ended"
  (let ([sleeper (git:start repo '("-c" "alias.nap=!sleep 30" "nap") (lambda (c) (void)))])
    (test-runner:wait-until (lambda () (git:running repo)))
    (check-equal? sleeper (git:running repo))
    (check (git:queued? repo))
    (git:stop! sleeper)
    (test-runner:wait-until (lambda () (git:command-exit sleeper)))
    (check-equal? -1 (git:command-exit sleeper))
    (check (not (git:queued? repo)))
    (check-equal? "Process isn't running" (guard (c [(error? c) (condition-message c)]) (git:stop! sleeper)))
    (check (not (git:command-canceled? sleeper)))
    (git:set-command-canceled! sleeper)
    (check (git:command-canceled? sleeper))))

(test "the log keeps the last git:command-log-size commands"
  (options:set! git:command-log-size 3)
  (git:run repo '("tag" "v5"))
  (check-equal? '((0 ("var" "GIT_EDITOR")) (-1 ("-c" "alias.nap=!sleep 30" "nap")) (0 ("tag" "v5"))) (log-lines repo))
  (options:unset! git:command-log-size))

(test "git:command-updated follows a command as it is queued, starts, gets output and ends"
  (let* ([seen '()]
         [note (lambda (r c)
                 (when (equal? (git:command-arguments c) '("tag" "--list"))
                   (set! seen (cons (cond
                                      [(git:command-exit c) 'ended]
                                      [(git:running repo) (if (string=? (git:command-output c) "") 'started 'output)]
                                      [else 'queued])
                                    seen))))])
    (hooks:add! git:command-updated note)
    (check-equal? "v1\nv2\nv3\nv4\nv5\n" (utf8->string (git:run repo '("tag" "--list"))))
    (hooks:remove! git:command-updated note)
    (let ([seen (reverse seen)])
      (check-equal? '(queued started) (list-head seen 2))
      (check (memq 'output seen))
      (check-equal? 'ended (car (reverse seen))))))

(test "git:program names the program run, and one that cannot start is reported and raises"
  (options:set! git:program "no-such-git")
  (let-values ([(message reported)
                (reports-during
                  (lambda () (guard (c [(error? c) (condition-message c)]) (git:run repo '("status")))))])
    (options:unset! git:program)
    (check-equal? "cannot run no-such-git: No such file or directory" message)
    (check-equal? 1 (length reported))
    (check-equal? message (condition-message (car reported)))))

(test "git:start's wrapper makes the receiver git's output goes through before it is logged"
  (let ([shouted (git:start repo '("rev-parse" "--abbrev-ref" "HEAD") (lambda (c) (void)) #f
                   (lambda (receive)
                     (lambda (bytes end)
                       (receive (if (eof-object? bytes) bytes (string->utf8 (string-upcase (utf8->string bytes)))) end))))])
    (test-runner:wait-until (lambda () (git:command-exit shouted)))
    (check-equal? "MAIN\n" (git:command-output shouted))))

(test "a command stopped while queued ends before it starts, with status -1"
  (let* ([waiting (git:start repo '("-c" "alias.wait=!while [ ! -e release ]; do sleep 0.01; done" "wait") (lambda (c) (void)))]
         [queued (git:start repo '("tag" "never") (lambda (c) (void)))])
    (test-runner:wait-until (lambda () (eq? (git:running repo) waiting)))
    (git:stop! queued)
    (git-test/repositories:write-file! "repo/release" "")
    (test-runner:wait-until (lambda () (not (git:queued? repo))))
    (check-equal? 0 (git:command-exit waiting))
    (check-equal? -1 (git:command-exit queued))
    (check-equal? "" (utf8->string (git:query repo '("tag" "--list" "never"))))))

(test "a command git:start cannot start is reported, and ends with status 127 and its reason in the output"
  (options:set! git:program "no-such-git")
  (let-values ([(command reported)
                (reports-during
                  (lambda ()
                    (let ([c (git:start repo '("status") (lambda (c) (void)))])
                      (test-runner:wait-until (lambda () (git:command-exit c)))
                      c)))])
    (options:unset! git:program)
    (check-equal? 127 (git:command-exit command))
    (check-equal? "cannot run no-such-git: No such file or directory\n" (git:command-output command))
    (check-equal? '("cannot run no-such-git: No such file or directory") (map condition-message reported))))
