(import (tuna) (test) (test-runner) (plugins) (options) (fixtures))

(define spell-root (fixtures:home-path "src" "spell" "src"))

(fixtures:write-module! spell-root '(spell)
  '((import (spell words) (hooks) (options) (fixtures))
    (options:define-option language "en" string? "The dictionary's language.")
    (hooks:define-hook after-check)
    (define (check w) (after-check w) (string-append (spell/words:lookup w) " in " (language)))
    (define-syntax with-word (syntax-rules () [(_ w e) (let ([w "word"]) e)]))
    (fixtures:note! 'spell-body)))
(fixtures:write-module! spell-root '(spell words) '((define (lookup w) (string-append "found " w))))

(define config-notes '(spell-config (internal "found a" macro "word") (hook "B") (after "found b in en-GB" "X")))

(fixtures:load-configuration!
  '((import (tuna) (hooks) (options) (fixtures))
    (use-plugin spell (local "~/src/spell")
      (config
        (fixtures:note! 'spell-config)
        (options:set! spell:language "en-GB")
        (define (shout w) (string-upcase w))
        (hooks:add! spell:after-check (lambda (w) (fixtures:note! (list 'hook (shout w)))))
        (fixtures:note! (list 'internal (spell/words:lookup "a") 'macro (spell:with-word w w)))))
    (fixtures:note! (list 'after (spell:check "b") (shout "x")))))

(define first-notes (fixtures:take-notes!))

(define (settings) (options:settings spell:language))

(test "a line's config forms run once the line has loaded the plugin, as top-level forms of the configuration that see every loaded module's names"
  (check-equal? (cons 'spell-body config-notes) first-notes)
  (check-equal? '(((init) "en-GB")) (settings)))

(test "reading the configuration again runs the config forms again, and the plugin keeps running"
  (let ([spell (module-owner '(spell))])
    (plugins:load-configuration!)
    (check-equal? config-notes (fixtures:take-notes!))
    (check-equal? spell (module-owner '(spell)))
    (check-equal? '(((init) "en-GB")) (settings))))

(test "a line evaluated alone as the configuration's runs its config forms as the configuration's"
  (fixtures:as-configuration '(use-plugin spell (local "~/src/spell") (config (options:set! spell:language "de"))))
  (check-equal? '(((init) "de")) (settings)))

(test "a reload of the plugin reads the configuration again, so only the file's config forms hold"
  (reload-modules! '((spell)))
  (check-equal? (cons 'spell-body config-notes) (fixtures:take-notes!))
  (check-equal? '(((init) "en-GB")) (settings)))

(test "an unload of the plugin reads the configuration again, which loads a new instance"
  (let ([old (module-owner '(spell))])
    (unload-owner! old)
    (check-equal? (cons 'spell-body config-notes) (fixtures:take-notes!))
    (check (not (owner-live? old)))
    (check (not (eq? old (module-owner '(spell)))))
    (check-equal? '(((init) "en-GB")) (settings))))

(test "a line evaluated at the REPL runs its config forms as the REPL's"
  (fixtures:at-repl '(use-plugin spell (local "~/src/spell") (config (options:set! spell:language "fr") (fixtures:note! 'typed))))
  (check-equal? '(typed) (fixtures:take-notes!))
  (check-equal? '(((repl) "fr") ((init) "en-GB")) (settings)))

(test "a config form that raises is reported, and the next one runs"
  (let ([reports (test-runner:reports-during
                   (lambda () (fixtures:at-repl '(use-plugin spell (local "~/src/spell") (config (car '()) (fixtures:note! 'next))))))])
    (check-equal? '(car) (map condition-who reports))
    (check-equal? '(next) (fixtures:take-notes!))))

(test "config is a line's last clause, and only a top-level line has one"
  (for-each
    (lambda (form)
      (check-equal? 'use-plugin
        (guard (c [(syntax-violation? c) (condition-who c)]) (fixtures:at-repl form))))
    '((begin (use-plugin spell (config (fixtures:note! 'nested))))
      (use-plugin spell (config (fixtures:note! 'first)) (local "~/src/spell"))))
  (check-equal? '() (fixtures:take-notes!)))

(test "a line that raises is reported once with its line, its config forms do not run, and each failing config form of a line that loads is reported with its line"
  (fixtures:write-module! (fixtures:home-path "src" "broken" "src") '(broken)
    '((import (options)) (options:define-option level 1 fixnum? "A level.") (car '())))
  (fixtures:write-file! (fixtures:home-path "src" "nothere" "src" "other.sls") "#!tuna\n(define (x) 1)\n")
  (fixtures:at-repl '(options:unset! spell:language))
  (fixtures:commit! "dict" '(("src/dict.sls" . "#!tuna\n(define (words) '(\"a\" \"b\"))\n")))
  (fixtures:write-file! (fixtures:configuration-path)
    (string-append
      "(import (tuna) (options) (fixtures))\n"
      "(use-plugin nothere (local \"~/src/nothere\") (config (fixtures:note! 'nothere)))\n"
      "(use-plugin dict (git \"" (fixtures:remote-url "dict") "\") (commit \"0000000\") (config (fixtures:note! 'dict)))\n"
      "(use-plugin broken (local \"~/src/broken\") (config (options:set! broken:level 3) (fixtures:note! 'broken)))\n"
      "(use-plugin spell (local \"~/src/spell\")\n"
      "  (config\n"
      "    (options:set! spell:language 42)\n"
      "    (fixtures:note! 'second)\n"
      "    (let ((x)) x)\n"
      "    (spell:check)\n"
      "    (raise (make-error))\n"
      "    (fixtures:note! 'last)))\n"
      "(fixtures:note! (list 'after (spell:language)))\n"))
  (let ([reports (test-runner:reports-during plugins:load-configuration!)])
    (check-equal? '(2 3 4 7 9 10 11) (map fixtures:reported-line reports))
    (check-equal? (list "plugin nothere holds no module (nothere)"
                        (string-append "commit 0000000 not found in " (fixtures:remote-url "dict"))
                        "() is not a pair")
                  (map fixtures:message (list-head reports 3)))
    (check-equal? '(second last (after "en")) (fixtures:take-notes!))
    (check-equal? '() (owner-changes (plugins:configuration-owner)))))
