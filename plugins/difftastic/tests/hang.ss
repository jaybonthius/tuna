(import (tuna) (test) (test-user) (test-runner) (processes) (options) (diff-sections) (git) (git-mode) (git-status) (difftastic)
        (difftastic-test) (git-status-test) (git-test repositories))

(git-test/repositories:write-file! "hanging-difft"
  "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Difftastic 0.68.0'; exit 0; fi\necho $$ > \"$HOME/hung\"\nexec sleep 617\n")
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "hanging-difft"))
(options:set! difftastic:program (git-test/repositories:path "hanging-difft"))

(define (alive? pid)
  (let-values ([(status out err) (processes:run "kill" (list "-0" pid))]) (eqv? status 0)))

(test "a run that never ends is stopped when the plugin unloads, and the diff stays git's"
  (difftastic-test:rewrapped! "repo")
  (test-runner:wait-until (lambda () (file-exists? (git-test/repositories:path "hung"))))
  (let ([pid (let ([t (call-with-input-file (git-test/repositories:path "hung") get-string-all)]) (substring t 0 (- (string-length t) 1)))])
    (check (alive? pid))
    (unload-owner! (module-owner '(difftastic)))
    (test-runner:wait-until (lambda () (not (alive? pid))))
    (check-equal? '() (difftastic-test:refined-faces))))
