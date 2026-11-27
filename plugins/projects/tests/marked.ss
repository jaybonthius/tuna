(import (tuna) (test) (projects) (trees))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(test "projects:find-marked gives the nearest folder up holding one of some file names, ending in /, or #f"
  (trees:write-file! "mod/go.mod" "module mod\n")
  (trees:run! "" "mkdir" "-p" "mod/a/b")
  (check-equal? (trees:path "mod/") (projects:find-marked (trees:path "mod/a/b") '("go.mod" "Cargo.toml")))
  (check-equal? #f (projects:find-marked (trees:path "mod/a/b") '("no-such-marker"))))

(test "projects:find-marked checks its arguments"
  (check-equal? '(projects:find-marked "not an absolute path") (violation (lambda () (projects:find-marked "mod" '("go.mod")))))
  (check-equal? '(projects:find-marked "not a list of file names")
    (violation (lambda () (projects:find-marked (trees:path "") '("a/b"))))))
