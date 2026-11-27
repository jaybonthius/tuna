(import (tuna) (test) (git) (plain-data) (repositories))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(test "git:find-repository gives the working tree's root and its git folder, each ending in /, from any folder in it"
  (repositories:sample! "repo")
  (let ([repo (git:find-repository (repositories:path "repo"))])
    (check (git:repository? repo))
    (check (not (git:repository? "repo")))
    (check-equal? (repositories:path "repo/") (git:repository-root repo))
    (check-equal? (repositories:path "repo/.git/") (git:repository-git-folder repo))
    (check-equal? "repo" (git:repository-name repo))
    (repositories:run! "" "mkdir" "-p" "repo/deep/er")
    (check-equal? repo (git:find-repository (repositories:path "repo/deep/er")))))

(test "git:find-repository gives #f for a folder no repository holds, and raises for a relative path"
  (check-equal? #f (git:find-repository (repositories:path "elsewhere")))
  (mkdir (repositories:path "plain"))
  (check-equal? #f (git:find-repository (repositories:path "plain")))
  (check-equal? '(git:find-repository "not an absolute path") (violation (lambda () (git:find-repository "repo")))))

(test "a repository is plain data"
  (repositories:sample! "data")
  (check (plain-data:plain-data? (git:find-repository (repositories:path "data")))))

(test "git:init makes the folder and a repository in it, logged as a command"
  (let ([made (git:init (repositories:path "fresh/new"))])
    (check-equal? (repositories:path "fresh/new/") (git:repository-root made))
    (check-equal? '((0 ("init"))) (map (lambda (c) (list (git:command-exit c) (git:command-arguments c))) (git:commands made)))))
