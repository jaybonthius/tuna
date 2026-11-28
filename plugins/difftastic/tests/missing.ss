(import (tuna) (test) (test-user) (test-runner) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic) (difftastic-test)
        (git-status-test))

(options:set! difftastic:program "no-such-difft")

(test "with difft missing, diffs are git's and one warning says difft could not be used, once a session"
  (let ([reports (test-runner:reports-during
                   (lambda ()
                     (let ([repo (difftastic-test:rewrapped! "repo")])
                       (test-runner:wait-until (lambda () (not (difftastic:available?))))
                       (git-mode:refresh-repository repo)
                       (git-status-test:settle!))))])
    (check-equal? '("difft could not be used: no-such-difft did not run")
                  (map condition-message (filter warning? reports)))
    (check-equal? '() (difftastic-test:refined-faces))))
