(import (tuna) (test) (projects) (projects-test trees))

(define above (path-parent (getenv "HOME")))

(test "a repository above the home folder holds no folder inside it, while it holds a folder outside it"
  (projects-test/trees:run! "" "mkdir" "-p" "notes")
  (check-equal? #f (projects-test/trees:root-of "notes"))
  (check-equal? (string-append above "/") (projects:root (projects:find (string-append above "/work")))))

(test "projects:find-marked stops at the home folder, which it looks in last"
  (projects-test/trees:run! "" "mkdir" "-p" "mod/a/b")
  (projects-test/trees:write-file! "home.marker" "")
  (check-equal? #f (projects:find-marked (projects-test/trees:path "mod/a/b") '("above.marker")))
  (check-equal? (projects-test/trees:path "") (projects:find-marked (projects-test/trees:path "mod/a/b") '("home.marker"))))
