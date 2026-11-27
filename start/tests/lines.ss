(import (tuna) (test) (test-runner) (plugins) (fixtures) (remotes))

(define no-source "the line for ~a has no source: give it a git or local clause, or use an index that names it")

(define (local-plugin! id files)
  (for-each (lambda (file) (fixtures:write-file! (fixtures:home-path "src" (symbol->string id) "src" (car file)) (cdr file)))
            files))

(test "an index's line comes before the lines that rely on it: a line read before it has no source and installs nothing"
  (let ([reports (test-runner:reports-during
                   (lambda ()
                     (fixtures:load-configuration!
                       `((import (tuna))
                         (use-plugin consult)
                         (use-plugin sources (git ,(remotes:url "sources")))))))])
    (check-equal? '(2) (map fixtures:reported-line reports))
    (check-equal? (list (format no-source 'consult)) (map fixtures:message reports))
    (check-equal? '(sources) (plugins:installed))))

(test "a line typed at the REPL with no source and no index naming it raises"
  (check-equal? (format no-source 'magit) (fixtures:raised-message (lambda () (fixtures:at-repl '(use-plugin magit))))))

(test "once the index is installed its lines give sources, and a plugin a line's plugin imports needs a line of its own"
  (fixtures:at-repl '(use-plugin compat))
  (fixtures:at-repl '(use-plugin consult))
  (check-equal? "compat buffer" (fixtures:at-repl '(consult:buffer))))

(test "an install whose plugin holds no main module, or whose commit is missing, installs nothing"
  (let ([line `(use-plugin empty (git ,(remotes:url "empty")))])
    (check-equal? '(install-plugin! "plugin empty holds no module (empty)")
      (guard (c [#t (list (condition-who c) (fixtures:message c))]) (plugins:install! line)))
    (check-equal? '(use-plugin "plugin empty holds no module (empty)")
      (guard (c [#t (list (condition-who c) (fixtures:message c))]) (fixtures:at-repl line))))
  (check-equal? (format "commit 0000000 not found in ~a" (remotes:url "vertico"))
    (fixtures:raised-message (lambda () (fixtures:at-repl `(use-plugin vertico (git ,(remotes:url "vertico")) (commit "0000000"))))))
  (check-equal? '(consult sources compat) (plugins:installed)))

(define notes-folder (fixtures:home-path "src" "notes"))
(local-plugin! 'notes `(("notes.sls" . ,(fixtures:module-text '((define (where) "notes from a local folder"))))))

(define configuration
  `((import (tuna) (fixtures))
    (use-plugin sources (git ,(remotes:url "sources")))
    (use-plugin compat (git ,(remotes:url "compat-fork")))
    (use-plugin consult)
    (use-plugin consult (git "https://example.org/second/consult"))
    (fixtures:note! (consult:buffer))
    (use-plugin embark)
    (use-plugin embark-consult (commit ,(fixtures:short (car (remotes:commits "embark")))))
    (use-plugin kill-ring)
    (use-plugin notes (local "~/src/notes"))))

(define second-line-reports
  (test-runner:reports-during
    (lambda ()
      (plugins:remove! 'compat)
      (plugins:remove! 'consult)
      (fixtures:load-configuration! configuration))))

(test "lines are read before the configuration runs, and a second line for an id is reported, the first being the one known"
  (check-equal? '("a second line for consult") (map fixtures:message second-line-reports))
  (check-equal? '(use-plugin) (map condition-who second-line-reports)))

(test "a line imports its plugin's main module, so the next form sees its names"
  (check-equal? '("bob's compat buffer") (fixtures:take-notes!)))

(test "a line's source is a git repository, a folder in one, a commit of one, a local folder, an index's line, or Tuna's own plugin"
  (check-equal? '("bob's compat" "bob's compat buffer") (fixtures:at-repl '(list (compat:who) (consult:buffer))))
  (check-equal? '("first" #t) (fixtures:at-repl '(list (embark-consult:version) (embark:integrated))))
  (check-equal? "notes from a local folder" (fixtures:at-repl '(notes:where)))
  (check (module-owner '(kill-ring)))
  (check-equal? 'tuna (plugins:module-source '(kill-ring)))
  (check-equal? notes-folder (plugins:module-source '(notes))))

(test "installed plugins are the configuration's lines' in order, then the others by id, and Tuna's own plugins are not among them"
  (check-equal? '(sources compat consult embark embark-consult notes) (plugins:installed)))

(test "Tuna writes nothing into the configuration while it reads it"
  (check-equal? (call-with-string-output-port
                  (lambda (p) (for-each (lambda (form) (write form p) (newline p)) configuration)))
                (fixtures:read-file (fixtures:configuration-path))))

(test "a line typed at the REPL is read before it is evaluated, so it installs a plugin no index names"
  (fixtures:at-repl `(use-plugin vertico (git ,(remotes:url "vertico"))))
  (check-equal? 10 (fixtures:at-repl '(vertico:count))))

(test "a plugin holding a library another provider holds is refused, and nothing of it is installed"
  (local-plugin! 'rival `(("rival.sls" . ,(fixtures:module-text '((define (x) 1))))
                          ("compat.sls" . ,(fixtures:module-text '((define (who) "rival"))))))
  (check-equal? "plugin rival and plugin compat both hold the library (compat)"
    (fixtures:raised-message (lambda () (fixtures:at-repl '(use-plugin rival (local "~/src/rival"))))))
  (check (not (memq 'rival (plugins:installed)))))

(test "a plugin holding a library name Tuna keeps for itself is refused"
  (local-plugin! 'keeper `(("keeper.sls" . ,(fixtures:module-text '((define (x) 1))))
                           ("lang/reader.sls" . ,(fixtures:module-text '((define (y) 1))))))
  (check-equal? "plugin keeper holds the library (lang reader), a name Tuna keeps for itself"
    (fixtures:raised-message (lambda () (fixtures:at-repl '(use-plugin keeper (local "~/src/keeper"))))))
  (check (not (memq 'keeper (plugins:installed)))))

(test "lines go only in the configuration and at the REPL, and plugin lines only in an index's main module"
  (fixtures:write-lib-module! '(uses) '((use-plugin vertico)))
  (check-equal? '(use-plugin)
    (guard (c [(syntax-violation? c) (list (syntax->datum (syntax-violation-form c)))]) (fixtures:at-repl '(import (uses)))))
  (local-plugin! 'plain `(("plain.sls" . ,(fixtures:module-text '((define (x) 1) (plugin compat (git "https://example.org/compat")))))))
  (check-equal? '(plugin)
    (guard (c [(syntax-violation? c) (list (syntax->datum (syntax-violation-form c)))])
      (fixtures:at-repl '(use-plugin plain (local "~/src/plain")))))
  (check-equal? '(plugin "a plugin line outside an index's main module")
    (guard (c [(syntax-violation? c) (list (condition-who c) (condition-message c))])
      (fixtures:at-repl `(plugin compat (git ,(remotes:url "compat-fork")))))))

(test "remove-unused! deletes the plugins with no line none of whose modules a lookup has found"
  (fixtures:write-file! (fixtures:home-path ".local" "share" "tuna" "plugins" "greet" "src" "greet.sls")
    (fixtures:module-text '((define (text) "hello"))))
  (check-equal? '(sources compat consult embark embark-consult notes greet plain vertico) (plugins:installed))
  (plugins:remove-unused!)
  (check-equal? '(sources compat consult embark embark-consult notes vertico) (plugins:installed))
  (check (not (file-exists? (fixtures:home-path ".local" "share" "tuna" "plugins" "greet"))))
  (check (file-exists? (fixtures:home-path "src" "plain" "src" "plain.sls"))))

(test "removing a local plugin unloads its module and comments out its line, and never deletes its folder; the configuration is read again"
  (check-equal? '("a second line for consult")
    (map fixtures:message (test-runner:reports-during (lambda () (plugins:remove! 'notes)))))
  (check (not (memq 'notes (plugins:installed))))
  (check (file-exists? (fixtures:home-path "src" "notes" "src" "notes.sls")))
  (check-equal? "module (notes) is unloaded" (fixtures:raised-message (lambda () (fixtures:at-repl '(notes:where)))))
  (check-equal? (call-with-string-output-port
                  (lambda (p)
                    (for-each (lambda (form)
                                (when (and (pair? form) (eq? (car form) 'use-plugin) (eq? (cadr form) 'notes))
                                  (put-string p "#;"))
                                (write form p)
                                (newline p))
                              configuration)))
                (fixtures:read-file (fixtures:configuration-path))))
