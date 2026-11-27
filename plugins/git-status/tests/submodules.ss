(import (tuna) (test) (test-user) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git) (git-mode) (git-status)
        (git-status-test) (git-test repositories))

(define git! git-test/repositories:git!)

(git! "" "init" "-q" "-b" "main" "lib")
(git-test/repositories:write-file! "lib/l.txt" "1\n")
(git! "lib" "add" "l.txt")
(git! "lib" "commit" "-qm" "one")
(git! "" "init" "-q" "-b" "main" "top")
(git! "top" "-c" "protocol.file.allow=always" "submodule" "-q" "add" "../lib" "lib")
(git! "top" "commit" "-qm" "sub")
(git-test/repositories:write-file! "top/lib/l.txt" "2\n")
(git! "top/lib" "commit" "-qam" "two")

(define repo (git:find-repository (git-status-test:path "top")))

(git-status:show repo)
(git-status-test:settle!)

(define (prefix n s) (if (> (string-length s) n) (substring s 0 n) s))

(test "a submodule whose checkout moved shows as a modified row whose body is the Subproject commit hunk"
  (check-equal? '("Head:     main sub" "Unstaged changes (1)" "modified   lib…" "Recent commits…") (git-status-test:status))
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "lib") '(unstaged . #f)))
  (check-equal? '("@@ -1 +1 @@" "-Subproject commit" "+Subproject commit")
                (map (lambda (l) (prefix 18 l)) (list-head (list-tail (git-status-test:status) 3) 3))))

(test "s stages the submodule's row"
  (git-status-test:go-to-section! '(file . "lib") '(unstaged . #f))
  (git-status-test:press! "s")
  (check-equal? "M  lib\n" (git-status-test:short "top")))

(test "k on it asks, and git's checkout leaves the submodule's own checkout"
  (git! "top" "reset" "-q")
  (git-mode:refresh-repository repo)
  (git-status-test:go-to-section! '(file . "lib") '(unstaged . #f))
  (git-status-test:answer! #t)
  (git-status-test:press! "k")
  (check-equal? '(("Discard unstaged changes in \"lib\"? ") " M lib\n" "two\n")
                (list (git-status-test:take-asked!) (git-status-test:short "top") (git-status-test:git-out "top/lib" "log" "-1" "--format=%s"))))

(test "RET on its row shows the submodule's own status buffer in the selected view"
  (git-status-test:go-to-section! '(file . "lib") '(unstaged . #f))
  (git-status-test:press! "RET")
  (check-equal? "*git: lib*" (git-status-test:shown-buffer)))
