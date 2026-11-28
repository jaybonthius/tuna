(import (tuna) (test) (test-runner) (plugins) (fixtures))


(fixtures:write-lib-module! '(boom) '((define (x) 1) (error 'boom "failed")))
(fixtures:write-lib-module! '(spell)
  '((define (language) "en")
    (define (dictionary-path) (string-append "/usr/share/dict/" (language)))
    (define (check path) (list path (dictionary-path)))))
(fixtures:write-lib-module! '(magit) '((import (magit git)) (define (status) (magit/git:run))))
(fixtures:write-lib-module! '(magit git) '((define-record-type thing (fields a)) (define (run) 'git-default)))
(fixtures:write-lib-module! '(magit later) '((define x 'later-x)))
(fixtures:write-lib-module! '(magit extra) '((define y 'extra-y)))
(fixtures:write-lib-module! '(saver) '((define (save! path) path)))

(define configuration
  '((import (tuna))
    (import (spell) (saver) (magit))
    (define spell:dictionary-path (lambda () "/home/groucho/words"))
    (define magit/git:run (lambda () 'mine))
    (define loaded-by (current-owner))
    (import (boom))
    (define after-boom (current-owner))
    (define spell:language (lambda () "fr"))
    (car '())
    (define after-error 'ran)))

(define first-reports (test-runner:reports-during (lambda () (fixtures:load-configuration! configuration))))

(test "the configuration loads form by form as (init); a form that raises is reported with its line, and the next form runs"
  (check-equal? '(6 9) (map fixtures:reported-line first-reports))
  (check-equal? 'car (condition-who (cadr first-reports)))
  (check-equal? (plugins:configuration-owner) loaded-by)
  (check-equal? '(init) (owner-name loaded-by))
  (check-equal? 'ran after-error))

(test "a module whose body raises is not loaded, and the configuration goes on as (init)"
  (check-equal? 'boom (condition-who (car first-reports)))
  ;; The failed body's unload ends between tasks, after the raise.
  (test-runner:wait-until (lambda () (not (module-owner '(boom)))))
  (check-equal? loaded-by after-boom))

(test "the configuration's define of a module's name overrides it, and the module's own code and its importers use the override"
  (check-equal? '("a.txt" "/home/groucho/words") (spell:check "a.txt"))
  (check-equal? 'mine (magit:status))
  (check-equal? '(((init) override) ((spell) define)) (fixtures:changes-of spell:language)))

(test "the configuration and the REPL see every loaded module's names, an internal module's record procedures included"
  (check-equal? 5 (fixtures:at-repl '(magit/git:thing-a (magit/git:make-thing 5)))))

(test "a module loaded within a form is seen from the next form"
  (check-equal? '("magit/later:x")
    (guard (c [(assertion-violation? c) (map symbol->string (condition-irritants c))])
      (fixtures:at-repl '(begin (load-module! '(magit later)) magit/later:x))))
  (check-equal? 'later-x (fixtures:at-repl 'magit/later:x)))

(test "at the REPL, a define of a module's name is an override, and so is one a macro expands to"
  (fixtures:at-repl '(define (spell:check path) "repl's"))
  (check-equal? "repl's" (spell:check "x"))
  (check-equal? '(((repl) override) ((spell) define)) (fixtures:changes-of spell:check))
  (fixtures:at-repl '(define-syntax define-quietly (syntax-rules () [(_ n v) (define n v)])))
  (fixtures:at-repl '(define-quietly saver:save! (lambda (path) 'quiet)))
  (check-equal? 'quiet (saver:save! "p"))
  (check-equal? '(((repl) override) ((saver) define)) (fixtures:changes-of saver:save!)))

(test "an override is a procedure"
  (check-equal? "not a procedure" (fixtures:raised-message (lambda () (fixtures:at-repl '(define-quietly saver:save! 'shadowed)))))
  (check (procedure? saver:save!)))

(test "a define of a prefixed name that no loaded module exports makes a variable, which a define sets again"
  (fixtures:at-repl '(define nothere:x 1))
  (fixtures:at-repl '(define mine:x 1))
  (fixtures:at-repl '(define mine:x 2))
  (check-equal? '(1 2) (fixtures:at-repl '(list nothere:x mine:x))))

(test "a module loaded after a top-level definition of one of its names replaces it, with no report"
  (fixtures:at-repl '(define magit/extra:y 'user))
  (check-equal? '() (test-runner:reports-during (lambda () (load-module! '(magit extra)))))
  (check-equal? 'extra-y (fixtures:at-repl 'magit/extra:y)))

(define unload-count 0)

(test "reading the configuration again takes back its changes, runs its unload actions, then runs the file as it is"
  (let ([before (plugins:configuration-owner)]
        [kinds (map car (owner-changes (plugins:configuration-owner)))])
    (check-equal? '(6 9) (map fixtures:reported-line (test-runner:reports-during plugins:load-configuration!)))
    (check (not (owner-live? before)))
    (check-equal? kinds (map car (owner-changes (plugins:configuration-owner)))))
  (check-equal? '()
    (test-runner:reports-during
      (lambda ()
        (fixtures:load-configuration!
          '((import (tuna) (spell))
            (define spell:dictionary-path (lambda () "/home/groucho/other-words"))
            (on-unload (lambda () (set! unload-count (+ unload-count 1)))))))))
  (check-equal? '(unload-action override) (map car (owner-changes (plugins:configuration-owner))))
  (check-equal? "/home/groucho/other-words" (spell:dictionary-path))
  (check-equal? 0 unload-count)
  (plugins:load-configuration!)
  (check-equal? 1 unload-count))

(fixtures:write-lib-module! '(greet) '((define (text name) (string-append "Hello, " name "!"))))
(fixtures:load-configuration! '((import (tuna) (greet))))

(test "a module of lib/ edited and reloaded runs its new code; the REPL's override and advice outlast its unload, after which the configuration loads it again"
  (check-equal? "Hello, Harpo!" (greet:text "Harpo"))
  (fixtures:write-lib-module! '(greet) '((define (text name) (string-append "Howdy, " name "!"))))
  (reload-modules! '((greet)))
  (check-equal? "Howdy, Harpo!" (greet:text "Harpo"))
  (fixtures:at-repl '(define greet:text (lambda (name) (string-append "Hi, " name "!"))))
  (check-equal? "Hi, Harpo!" (greet:text "Harpo"))
  (fixtures:at-repl '(advice-add! greet:text (lambda (text name) (string-upcase (text name)))))
  (check-equal? "HI, HARPO!" (greet:text "Harpo"))
  (let ([old (module-owner '(greet))])
    (unload-owner! old)
    (check (module-owner '(greet)))
    (check (not (eq? old (module-owner '(greet))))))
  (check-equal? "HI, HARPO!" (greet:text "Harpo")))

(test "a module whose file has come to import another since it loaded is not that one's importer, so that one's reload leaves the configuration loaded"
  (fixtures:write-lib-module! '(speller) '((define (n) 1)))
  (fixtures:write-lib-module! '(spelling) '((define (word) "fish")))
  (fixtures:load-configuration! '((import (tuna) (speller))))
  (fixtures:at-repl '(import (spelling)))
  (fixtures:write-lib-module! '(speller) '((import (spelling)) (define (n) (string-length (spelling:word)))))
  (let ([before (plugins:configuration-owner)])
    (reload-modules! '((spelling)))
    (check-equal? before (plugins:configuration-owner))
    (check-equal? 1 (fixtures:at-repl '(speller:n)))))
