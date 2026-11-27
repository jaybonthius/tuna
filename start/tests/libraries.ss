(import (tuna) (test) (plugins) (fixtures) (remotes))

(define adder-commits (remotes:commits "chez-adder"))
(define libraries-folder (fixtures:home-path ".local" "share" "tuna" "libraries"))
(define (warnings-during thunk) (map fixtures:message (fixtures:reports-during thunk)))

(define first-reports
  (fixtures:reports-during
    (lambda ()
      (fixtures:load-configuration!
        `((import (tuna))
          (use-plugin sum (git ,(remotes:url "sum")))
          (use-plugin total (git ,(remotes:url "total"))))))))

(test "plugins asking for one library at commits on one line of history get the one that descends from the others, built before the configuration runs and found in its own folders"
  (check-equal? '() first-reports)
  (check-equal? 3 (fixtures:at-repl '(sum:total 1 2)))
  (check-equal? "3" (fixtures:at-repl '(total:version)))
  (check-equal? 5 (fixtures:at-repl '(begin (import (adder)) (adder-sum 2 3))))
  (check-equal? (caddr adder-commits) (fixtures:git! (string-append libraries-folder "/chez-adder") "rev-parse" "HEAD")))

(test "a library's build runs in its folder with SCHEME set to Tuna's own Chez, and Chez compiles it into the library's own object folder"
  (check-equal? (scheme-version) (fixtures:at-repl 'adder-built-with))
  (check (file-exists? (string-append libraries-folder "/chez-adder/build/obj/src/adder.so"))))

(test "when no commit asked for descends from all the others the library is refused, naming the line to add, and the loaded library stays"
  (check-equal?
    (apply format "plugin odd needs library chez-adder: plugin sum asks for chez-adder at commit ~a, plugin total at commit ~a and plugin odd at commit ~a, and none descends from all the others; add (library chez-adder (commit \"...\")) to init.ss"
      (map fixtures:short (list (car adder-commits) (caddr adder-commits) (cadr adder-commits))))
    (fixtures:raised-message (lambda () (fixtures:at-repl `(use-plugin odd (git ,(remotes:url "odd")))))))
  (check-equal? "3" (fixtures:at-repl '(adder-version))))

(test "a line typed at the REPL wins over every plugin's, each it replaces reported, and a loaded library's new line waits for the next start"
  (check-equal? '("the REPL's line for library chez-adder replaces that of plugin sum"
                  "the REPL's line for library chez-adder replaces that of plugin total"
                  "library chez-adder is loaded, so its new line takes effect when Tuna starts again")
    (warnings-during (lambda () (fixtures:at-repl `(library chez-adder (commit ,(fixtures:short (cadr adder-commits))))))))
  (check-equal? "3" (fixtures:at-repl '(adder-version))))

(test "a library line is data, never Chez's library form"
  (check-equal? '(library "expected an id and clauses (git url) with (commit hex), (local folder), (library-directories root ...) or (build program argument ...)")
    (guard (c [(syntax-violation? c) (list (condition-who c) (condition-message c))])
      (fixtures:at-repl '(library chez-adder (local))))))
