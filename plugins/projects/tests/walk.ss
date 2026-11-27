(import (tuna) (test) (test-runner) (trees))

;; The walk's stop is the home folder, so a child Tuna whose home is a
;; folder of this test's own home has above it a repository and a marker
;; that no other test file's walk can reach.
(test "inside the home folder the walk looks there last and stops; outside it the walk goes up to /"
  (trees:run! "" "mkdir" "-p" "above/.git" "above/home")
  (trees:write-file! "above/above.marker" "")
  (let-values ([(status errors) (test-runner:run-file "walk/inside.ss" (trees:path "above/home"))])
    (check-equal? 0 status)
    (check-equal? "" errors)))
