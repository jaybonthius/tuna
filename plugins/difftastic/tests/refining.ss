(import (tuna) (test) (test-user) (test-runner) (options) (tables) (views) (ui) (diff-sections) (git) (git-mode) (git-status) (git-apply)
        (difftastic) (difftastic-test) (git-status-test) (git-test repositories))

(define repo (difftastic-test:rewrapped! "repo"))

(test "loaded, the plugin is the refiner diff-sections draws with, and one of diff-sections:refiners"
  (check (eq? difftastic:refiner (diff-sections:refiner)))
  (check (tables:ref diff-sections:refiners difftastic:refiner #f)))

(test "with difft installed, a shown file's new tokens are drawn stronger and its rewrapped lines dimmed; the text stays git's"
  (test-runner:wait-until (lambda () (pair? (difftastic-test:refined-faces))))
  (check-equal? '(("diff-sections.reformatted" "    foo(x,") ("diff-sections.reformatted" "        y)") ("diff-sections.novel-removed" "2")
                  ("diff-sections.reformatted" "    foo(x, y)") ("diff-sections.novel-added" "3"))
                (difftastic-test:refined-faces))
  (check (member "-    foo(x," (git-status-test:status))))

(test "s on the refined hunk stages git's lines, and the staged diff is refined as it is shown"
  (git-status-test:go-to-section! '(file . "a.py") '(unstaged . #f))
  (git-status-test:press! "s")
  (check-equal? "M  a.py\n" (git-status-test:short "repo"))
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "a.py") '(staged . #f)))
  (test-runner:wait-until (lambda () (pair? (difftastic-test:refined-faces))))
  (check (member '("diff-sections.novel-added" "3") (difftastic-test:refined-faces))))

(test "unloading the plugin takes its refiner back, and the spans go at the next refinement"
  (unload-owner! (module-owner '(difftastic)))
  (check-equal? #f (diff-sections:refiner))
  (git-mode:refresh-repository repo)
  (git-status-test:settle!)
  (check-equal? '() (difftastic-test:refined-faces)))
