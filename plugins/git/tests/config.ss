(import (tuna) (test) (git) (repositories))

(repositories:sample! "repo")

(define repo (git:find-repository (repositories:path "repo")))

(test "git:config reads a key's value or #f, and git:set-config! sets a key or removes it with #f"
  (check-equal? "../origin-repo.git" (git:config repo "remote.origin.url"))
  (check-equal? #f (git:config repo "no.such-key"))
  (git:set-config! repo "tuna.test" "yes")
  (check-equal? "yes" (git:config repo "tuna.test"))
  (git:set-config! repo "tuna.test" #f)
  (check-equal? #f (git:config repo "tuna.test"))
  (git:set-config! repo "tuna.test" #f))

(test "git:remotes and git:remote-branches name the remotes and their branches"
  (check-equal? '("origin") (git:remotes repo))
  (repositories:git! "repo" "remote" "add" "fork" "../origin-repo.git")
  (repositories:git! "repo" "fetch" "-q" "fork")
  (check-equal? '("fork" "origin") (git:remotes repo))
  (check-equal? '("fork/main" "origin/main") (git:remote-branches repo)))

(test "git:upstream gives a branch's upstream, and git:push-remote its pushRemote, else remote.pushDefault, else #f"
  (check-equal? "origin/main" (git:upstream repo "main"))
  (check-equal? #f (git:upstream repo "nowhere"))
  (check-equal? #f (git:push-remote repo "main"))
  (git:set-config! repo "remote.pushDefault" "origin")
  (check-equal? "origin" (git:push-remote repo "main"))
  (git:set-config! repo "branch.main.pushRemote" "fork")
  (check-equal? "fork" (git:push-remote repo "main")))

(test "git:user gives user.name and user.email"
  (check-equal? '(#f #f) (call-with-values (lambda () (git:user repo)) list))
  (repositories:git! "repo" "config" "user.name" "Ada")
  (repositories:git! "repo" "config" "user.email" "ada@example.org")
  (check-equal? '("Ada" "ada@example.org") (call-with-values (lambda () (git:user repo)) list)))
