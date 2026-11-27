(import (tuna) (test) (plugins) (fixtures) (remotes))

(define adder-commits (remotes:commits "chez-adder"))
(define libraries-folder (fixtures:home-path ".local" "share" "tuna" "libraries"))
(define (warnings-during thunk) (map fixtures:message (fixtures:reports-during thunk)))
(define expected-library-line
  '(library "expected an id and clauses (git url) with (commit hex), (local folder), (library-directories root ...) or (build program argument ...)"))
(define (raised-syntax form)
  (guard (c [(syntax-violation? c) (list (condition-who c) (condition-message c))]) (fixtures:at-repl form) #f))

(define (library-text name body)
  (fixtures:forms-text `((library ,name (export ,(car body)) (import (chezscheme)) (define (,(car body)) ,(cadr body))))))

(fixtures:write-file! (fixtures:home-path ".config" "tuna" "lib" "mine" "thing.sls") (library-text '(mine thing) '(mine-thing "from lib/")))
(fixtures:write-file! (fixtures:home-path "src" "mine" "mine" "thing.sls") (library-text '(mine thing) '(mine-thing "from ~/src/mine")))
(fixtures:write-file! (fixtures:home-path "src" "mine" "mine" "other.sls") (library-text '(mine other) '(mine-other "from ~/src/mine")))

(define first-warnings
  (warnings-during
    (lambda ()
      (fixtures:load-configuration!
        `((import (tuna))
          (library chez-adder (commit ,(fixtures:short (cadr adder-commits))))
          (use-plugin sum (git ,(remotes:url "sum")))
          (use-plugin odd (git ,(remotes:url "odd"))))))))

(test "the configuration's line for a library may give only a commit, taking the rest from the plugins' lines, and wins over theirs, each it replaces reported"
  (check-equal? '("the configuration's line for library chez-adder replaces that of plugin sum") first-warnings)
  (check-equal? "2" (fixtures:at-repl '(odd:version)))
  (check-equal? 4 (fixtures:at-repl '(sum:total 2 2))))

(test "a library from a local folder with no library-directories has the folder as its root and its objects in Tuna's cache"
  (check-equal? (list (format "(mine thing) in lib/ replaces ~a" (fixtures:home-path "src" "mine" "mine" "thing.sls")))
    (warnings-during (lambda () (fixtures:at-repl '(library mine (local "~/src/mine"))))))
  (check-equal? "from ~/src/mine" (fixtures:at-repl '(begin (import (mine other)) (mine-other))))
  (check (file-exists? (fixtures:home-path ".cache" "tuna" "libraries" "mine" "mine" "other.so"))))

(test "a module in lib/ wins over a library's of the same name"
  (check-equal? "from lib/" (fixtures:at-repl '(begin (import (mine thing)) (mine-thing)))))

(test "a library holding a Tuna module is refused, since a plugin's modules must be able to reload"
  (check-equal? "library chez-modular holds the Tuna module (modular); install it with a use-plugin line"
    (fixtures:raised-message
      (lambda ()
        (fixtures:at-repl `(library chez-modular (git ,(remotes:url "chez-modular"))
                             (commit ,(fixtures:short (car (remotes:commits "chez-modular")))) (library-directories "src")))))))

(test "a library holding a library another provider holds is refused"
  (check-equal? "library chez-twin and library chez-adder both hold the library (adder)"
    (fixtures:raised-message
      (lambda ()
        (fixtures:at-repl `(library chez-twin (git ,(remotes:url "chez-twin"))
                             (commit ,(fixtures:short (car (remotes:commits "chez-twin")))) (library-directories "src")))))))

(test "a refused library is not left installed, and the libraries of Tuna's own plugins are the install's own"
  (check-equal? '("chez-adder" "chez-adder.installed") (sort string<? (directory-list libraries-folder))))

(test "a plugin's tuna.deps holds only library lines with a git source and a commit"
  (check-equal? (format "~a/broken-deps/tuna.deps holds (library chez-adder (local \"/tmp\")), which is not a library line with a git source and a commit"
                  (fixtures:home-path ".local" "share" "tuna" "plugins"))
    (fixtures:raised-message (lambda () (fixtures:at-repl `(use-plugin broken-deps (git ,(remotes:url "broken-deps"))))))))

(test "a library line with a git source needs a commit, and one with a local folder takes none"
  (check-equal? expected-library-line (raised-syntax `(library chez-adder (git ,(remotes:url "chez-adder")))))
  (check-equal? expected-library-line (raised-syntax '(library mine (local "~/src/mine") (commit "98df19e")))))

(test "a library nothing asks for any more goes with the unused plugins"
  (fixtures:at-repl `(use-plugin uses-extra (git ,(remotes:url "uses-extra"))))
  (check-equal? '("chez-adder" "chez-adder.installed" "chez-extra" "chez-extra.installed") (sort string<? (directory-list libraries-folder)))
  (plugins:remove! 'uses-extra)
  (plugins:remove-unused!)
  (check-equal? '("chez-adder" "chez-adder.installed") (sort string<? (directory-list libraries-folder)))
  (check-equal? '(sum odd) (plugins:installed)))

(test "a library line typed at the REPL replaces the configuration's for the session"
  (check-equal? '("the REPL's line for library chez-adder replaces that of the configuration"
                  "the REPL's line for library chez-adder replaces that of plugin sum"
                  "the REPL's line for library chez-adder replaces that of plugin odd"
                  "library chez-adder is loaded, so its new line takes effect when Tuna starts again")
    (warnings-during (lambda () (fixtures:at-repl `(library chez-adder (commit ,(fixtures:short (caddr adder-commits)))))))))

(test "library lines go only at the top level, since they are read before anything runs"
  (check-equal? '((library "a library line goes at the top level of the configuration or the REPL"))
    (map (lambda (c) (list (condition-who c) (fixtures:message c)))
         (fixtures:reports-during
           (lambda ()
             (fixtures:at-repl `(use-plugin sum (git ,(remotes:url "sum"))
                                  (config (library chez-other (commit ,(fixtures:short (caddr adder-commits))))))))))))
