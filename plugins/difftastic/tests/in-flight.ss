(import (tuna) (test) (test-user) (test-runner) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic)
        (difftastic-test) (git-status-test) (git-test repositories))

;; The slow run must still be going when difftastic:arguments changes,
;; so with --slow the fake program waits to be let go.
(git-test/repositories:write-file! "fake-difft"
  (string-append "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Difftastic 0.68.0'; exit 0; fi\n"
                 "if [ \"$3\" = --slow ]; then touch \"$HOME/slow-started\"; while [ ! -e \"$HOME/release\" ]; do sleep 0.05; done;\n"
                 "  echo \"{\\\"path\\\":\\\"$4\\\",\\\"status\\\":\\\"changed\\\",\\\"chunks\\\":[[{\\\"rhs\\\":{\\\"line_number\\\":2,\\\"changes\\\":[{\\\"start\\\":11,\\\"end\\\":12}]}}]],\\\"aligned_lines\\\":[[0,0]]}\"\n"
                 "else echo \"{\\\"path\\\":\\\"$3\\\",\\\"status\\\":\\\"unchanged\\\"}\"; fi\n"))
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "fake-difft"))
(options:set! difftastic:program (git-test/repositories:path "fake-difft"))
(options:set! difftastic:arguments '("--slow"))

(define delivered 0)

(advice-add! diff-sections:deliver! (lambda (next . arguments) (apply next arguments) (set! delivered (+ delivered 1))))

(test "an answer from a run that began before difftastic:arguments changed is not kept; the run after the change is"
  (let ([repo (difftastic-test:rewrapped! "repo")])
    (test-runner:wait-until (lambda () (file-exists? (git-test/repositories:path "slow-started"))))
    (options:set! difftastic:arguments '())
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (test-runner:wait-until (lambda () (= delivered 1)))
    (git-test/repositories:write-file! "release" "")
    (test-runner:wait-until (lambda () (= delivered 2)))
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (check (pair? (difftastic-test:refined-faces)))
    (check (for-all (lambda (f) (equal? "diff-sections.reformatted" (car f))) (difftastic-test:refined-faces)))))
