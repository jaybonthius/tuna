(import (tuna) (test) (test-runner) (git) (git-test repositories))

(git-test/repositories:sample! "repo")

(define repo (git:find-repository (git-test/repositories:path "repo")))

(test "a reload of git keeps each repository's queue and log: a command called after it waits for one running from before"
  (let* ([old-ended #f] [new-ended #f]
         [waiting (git:start repo '("-c" "alias.wait=!while [ ! -e release ]; do sleep 0.01; done" "wait")
                    (lambda (c) (set! old-ended (real-time))))])
    (test-runner:wait-until (lambda () (git:running repo)))
    (reload-modules! '((git)))
    (check-equal? waiting (git:running repo))
    (check (git:queued? repo))
    (let ([after (spawn-task (lambda (restore) (git:run repo '("tag" "after-reload")) (set! new-ended (real-time))))])
      (test-runner:wait-until
        (lambda () (exists (lambda (c) (equal? '("tag" "after-reload") (git:command-arguments c))) (git:commands repo))))
      (check-equal? #f (git:command-exit waiting))
      (git-test/repositories:write-file! "repo/release" "")
      (test-runner:join after))
    (check (and old-ended (< old-ended new-ended)))
    (check-equal? '(("-c" "alias.wait=!while [ ! -e release ]; do sleep 0.01; done" "wait") ("tag" "after-reload"))
      (map git:command-arguments (git:commands repo)))
    (check-equal? '(0 0) (map git:command-exit (git:commands repo)))))
