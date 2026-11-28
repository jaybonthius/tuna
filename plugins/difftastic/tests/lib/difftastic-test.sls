#!tuna
(import (test-runner) (test-user) (buffers) (views) (layout) (ui) (git) (git-mode) (git-status) (git-status-test) (git-test repositories))

;; A rewrapped call and an edit of a number, as difftastic tells them
;; apart: the rewrap has no new token, the edit has one.
(define (rewrapped! name)
  (let ([git! git-test/repositories:git!])
    (git! "" "init" "-q" "-b" "main" name)
    (git! name "config" "user.name" "Tuna")
    (git! name "config" "user.email" "tuna@example.org")
    (git-test/repositories:write-file! (string-append name "/a.py") "def f():\n    foo(x,\n        y)\n    return 2\n")
    (git! name "add" "a.py")
    (git! name "commit" "-qm" "one")
    (git-test/repositories:write-file! (string-append name "/a.py") "def f():\n    foo(x, y)\n    return 3\n")
    (let ([repo (git:find-repository (git-test/repositories:path name))])
      (git-status:show repo)
      (git-status-test:settle!)
      (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "a.py") '(unstaged . #f)))
      repo)))

(define (refined-faces)
  (test-user:settle)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (filter (lambda (e) (member (test-user:element-attribute e "data-face")
                                   '("diff-sections.novel-added" "diff-sections.novel-removed" "diff-sections.reformatted")))
               (test-user:elements-with (test-user:screen) "data-face"))))
