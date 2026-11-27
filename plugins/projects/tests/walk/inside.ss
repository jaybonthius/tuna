(import (tuna) (test) (projects) (trees))

(define above (path-parent (getenv "HOME")))

(test "a repository above the home folder holds no folder inside it, while it holds a folder outside it"
  (trees:run! "" "mkdir" "-p" "notes")
  (check-equal? #f (trees:root-of "notes"))
  (check-equal? (string-append above "/") (projects:root (projects:find (string-append above "/work")))))

(test "projects:find-marked stops at the home folder, which it looks in last"
  (trees:run! "" "mkdir" "-p" "mod/a/b")
  (trees:write-file! "home.marker" "")
  (check-equal? #f (projects:find-marked (trees:path "mod/a/b") '("above.marker")))
  (check-equal? (trees:path "") (projects:find-marked (trees:path "mod/a/b") '("home.marker"))))
