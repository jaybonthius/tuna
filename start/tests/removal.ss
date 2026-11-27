(import (tuna) (test) (plugins) (fixtures) (remotes))

(define plugins-folder (fixtures:home-path ".local" "share" "tuna" "plugins"))

(define (write-mine! forms) (fixtures:write-lib-module! '(mine) forms))

(fixtures:write-file! (string-append plugins-folder "/kill-ring/src/kill-ring.sls")
  (fixtures:module-text '((define (where) "a copy"))))
(fixtures:write-file! (string-append plugins-folder "/kill-ring.installed") "((git \"https://example.org/kill-ring\"))\n")
(fixtures:write-file! (fixtures:home-path "src" "other" "src" "other.sls") (fixtures:module-text '((define (name) "other"))))
(write-mine! '((define (text) "one")))

(define first-reports
  (fixtures:reports-during
    (lambda ()
      (fixtures:load-configuration!
        `((import (tuna))
          (use-plugin other (local "~/src/other"))
          (use-plugin sources (git ,(remotes:url "sources")))
          (use-plugin compat)
          (use-plugin consult)
          (use-plugin kill-ring)
          (import (mine)))))))

(test "a copy of one of Tuna's own plugins goes, with a warning, when the line for it has no source and no index names it"
  (check-equal? (list (format "removed ~a/kill-ring: its line finds the plugin among Tuna's own plugins" plugins-folder))
    (map fixtures:message first-reports))
  (check (warning? (car first-reports)))
  (check-equal? 'tuna (plugins:module-source '(kill-ring)))
  (check (not (file-exists? (string-append plugins-folder "/kill-ring"))))
  (check-equal? '(other sources compat consult) (plugins:installed)))

(test "a module reloads after a plugin is removed, though Chez keeps the removed plugin's library"
  (plugins:remove! 'other)
  (write-mine! '((define (text) "two")))
  (reload-modules! '((mine)))
  (check-equal? "two" (fixtures:at-repl '(mine:text)))
  (plugins:remove! 'consult)
  (check-equal? '(sources compat) (plugins:installed))
  (write-mine! '((define (text) "three")))
  (reload-modules! '((mine)))
  (check-equal? "three" (fixtures:at-repl '(mine:text))))

(test "a line typed at the REPL installs a removed plugin again"
  (fixtures:at-repl '(use-plugin other (local "~/src/other")))
  (check-equal? "other" (fixtures:at-repl '(other:name))))

(test "a module that comes to import another plugin needs that plugin's line, whose source an index may give"
  (fixtures:at-repl '(use-plugin embark))
  (write-mine! '((import (embark)) (define (text) (embark:act))))
  (reload-modules! '((mine)))
  (check-equal? "embark act" (fixtures:at-repl '(mine:text)))
  (check-equal? '(sources compat embark other) (plugins:installed)))

(test "a line evaluated as the configuration's is a configuration line"
  (fixtures:as-configuration `(use-plugin vertico (git ,(remotes:url "vertico"))))
  (check-equal? 10 (fixtures:at-repl '(vertico:count)))
  (check-equal? '(sources compat vertico embark other) (plugins:installed)))

(test "an id names a folder, so a path is not an id"
  (for-each
    (lambda (thunk) (check-equal? "not a plugin id" (fixtures:raised-message thunk)))
    (list (lambda () (plugins:remove! '|.|))
          (lambda () (plugins:remove! '..))
          (lambda () (plugins:update! '..))
          (lambda () (plugins:commit '|a/b|))))
  (check-equal? "not a use-plugin line" (fixtures:raised-message (lambda () (plugins:install! '(use-plugin |.| (local "~/src/other")))))))

(test "a plugin installed from another source than its line's, such as a copy put in place by hand, is installed from the line with a warning"
  (let ([commits (remotes:commits "spell")] [spell-folder (string-append plugins-folder "/spell")])
    (fixtures:write-file! (string-append spell-folder "/src/spell.sls") (fixtures:module-text '((define (dictionary-path) "a copy"))))
    (let ([reports (fixtures:reports-during
                     (lambda ()
                       (fixtures:load-configuration!
                         `((import (tuna) (options))
                           (use-plugin spell (git ,(remotes:url "spell")) (commit ,(fixtures:short (car commits))))
                           (options:set! spell:language "en-GB")
                           (define spell:dictionary-path (lambda () "/home/groucho/words"))))))])
      (check-equal? (list (format "replaced ~a, installed from another source or commit than its line's" spell-folder))
        (map fixtures:message reports))
      (check-equal? (car commits) (plugins:commit 'spell))
      (check-equal? '("/home/groucho/words" "en-GB") (fixtures:at-repl '(list (spell:dictionary-path) (spell:language)))))))

(test "a changed commit leaves the loaded plugin alone; once it is unloaded, the configuration read again installs the line's commit with its settings"
  (let ([commits (remotes:commits "spell")])
    (fixtures:write-configuration!
      `((import (tuna) (options))
        (use-plugin spell (git ,(remotes:url "spell")) (commit ,(fixtures:short (cadr commits))))
        (options:set! spell:language "en-GB")
        (define spell:dictionary-path (lambda () "/home/groucho/words"))))
    (plugins:load-configuration!)
    (check-equal? (car commits) (plugins:commit 'spell))
    (check-equal? (list (format "replaced ~a/spell, installed from another source or commit than its line's" plugins-folder))
      (map fixtures:message (fixtures:reports-during (lambda () (unload-owner! (module-owner '(spell)))))))
    (check-equal? (cadr commits) (plugins:commit 'spell))
    (check-equal? '("/home/groucho/words" "en-GB") (fixtures:at-repl '(list (spell:dictionary-path) (spell:language))))))
