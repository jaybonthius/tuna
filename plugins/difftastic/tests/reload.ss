(import (tuna) (test) (test-user) (test-runner) (options) (ask) (buffers) (layout) (diff-sections) (git) (git-mode) (git-status) (git-diff) (difftastic)
        (difftastic-test) (git-status-test) (git-test repositories))

(define (diff-buffer) (buffers:find "*git-diff: repo*"))

(git-test/repositories:write-file! "hanging-difft"
  "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Difftastic 0.68.0'; exit 0; fi\necho $$ > \"$HOME/hung\"\nexec sleep 619\n")
(git-test/repositories:run! "" "chmod" "+x" (git-test/repositories:path "hanging-difft"))
(options:set! difftastic:program (git-test/repositories:path "hanging-difft"))

(test "a run cut short by a reload of the plugin leaves its files to be refined again by the reloaded plugin"
  (let ([repo (difftastic-test:rewrapped! "repo")])
    (test-runner:wait-until (lambda () (file-exists? (git-test/repositories:path "hung"))))
    (options:set! difftastic:program "difft")
    (reload-modules! '((difftastic)))
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (test-runner:wait-until (lambda () (pair? (difftastic-test:refined-faces))))
    (check (member '("diff-sections.novel-added" "3") (difftastic-test:refined-faces)))))

(define (faces-in-view)
  (test-user:settle)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (filter (lambda (e) (member (test-user:element-attribute e "data-face")
                                   '("diff-sections.novel-added" "diff-sections.novel-removed" "diff-sections.reformatted")))
               (test-user:elements-with (git-status-test:drawn) "data-face"))))

(test "a buffer whose refiner was picked by D C-u t draws plain after the refiner's plugin reloads, and one D t brings the live refiner back"
  (let ([repo (git:find-repository (git-test/repositories:path "repo"))])
    (layout:select! (layout:display-buffer (git-diff:show repo (git-diff:unstaged-spec) '())))
    (git-status-test:settle!)
    (options:set! ask:choice-reader (lambda (q choices) (cdr (car choices))))
    (git-status-test:press! "D C-u t")
    (options:unset! ask:choice-reader)
    (check (buffers:with-buffer (diff-buffer) (options:local? diff-sections:refiner)))
    (reload-modules! '((difftastic)))
    (check (not (eq? (diff-sections:refiner) (buffers:with-buffer (diff-buffer) (diff-sections:refiner)))))
    (git-test/repositories:write-file! "repo/a.py" "def f():\n    foo(x, y)\n    return 5\n")
    (check-equal? '() (git-status-test:press-reporting! "g"))
    (check-equal? '() (faces-in-view))
    (git-status-test:press! "D t")
    (test-runner:wait-until (lambda () (pair? (faces-in-view))))
    (check (member '("diff-sections.novel-added" "5") (faces-in-view)))))
