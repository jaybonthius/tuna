(import (tuna) (test) (test-user) (test-runner) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic) (difftastic-test)
        (git-status-test) (git-test repositories))

(git-test/repositories:write-file! "old-difft" "#!/bin/sh\necho 'Difftastic 0.67.0'\n")
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "old-difft"))
(options:set! difftastic:program (git-test/repositories:path "old-difft"))

(test "with a difft older than 0.68, diffs are git's and one warning says so"
  (let ([reports (test-runner:reports-during
                   (lambda ()
                     (difftastic-test:rewrapped! "repo")
                     (test-runner:wait-until (lambda () (not (difftastic:available?))))
                     (git-status-test:settle!)))])
    (check-equal? (list (string-append "difft could not be used: " (git-test/repositories:path "old-difft") " is older than 0.68"))
                  (map condition-message (filter warning? reports)))
    (check-equal? '() (difftastic-test:refined-faces))))
