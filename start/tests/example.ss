(import (tuna) (test) (plugins) (options) (hooks) (tables) (scopes) (fixtures))

(define (at-repl form) (fixtures:at-repl form))

(fixtures:write-lib-module! '(saver)
  '((import (hooks) (options) (tables) (fixtures))
    (hooks:define-hook after-save "Called with the path of each file saved.")
    (hooks:define-hook before-save)
    (options:define-option autosave-seconds 0 real?)
    (tables:define-table modes)
    (define (save! path) "Saves the file at a path." (before-save path) (after-save path) path)))
(fixtures:write-lib-module! '(fill) '((import (options)) (options:define-option column 70 fixnum? "Width of filled lines.")))
(fixtures:write-lib-module! '(prog)
  '((import (fill) (hooks) (options) (fixtures))
    (hooks:define-hook mode-hook)
    (define (indent-buffer . arguments) (fixtures:note! 'indent))
    (define (mode) (mode-hook))
    (options:set! fill:column 90)))
(fixtures:write-lib-module! '(spell)
  '((import (saver) (hooks) (options) (fixtures))
    (options:define-option language "en" string?)
    (define (dictionary-path) (string-append "/usr/share/dict/" (language)))
    (define (check path) (fixtures:note! (list 'check path (dictionary-path))))
    (hooks:add! saver:after-save check)))

(fixtures:load-configuration!
  '((import (tuna) (hooks) (options) (fixtures))
    (import (spell) (saver) (fill) (prog))
    (options:set! spell:language "en-GB" fill:column 80 saver:autosave-seconds 30)
    (define spell:dictionary-path (lambda () "/home/groucho/words"))
    (define (announce save! path) (fixtures:note! (list 'announce path)) (save! path))
    (advice-add! saver:save! announce)
    (hooks:remove! saver:after-save spell:check)
    (hooks:add! prog:mode-hook
      (lambda ()
        (options:set-local! fill:column 100)
        (hooks:add-local! saver:before-save prog:indent-buffer -10)))))

(test "the configuration's changes are its owner's, ranked above every module's, and a module's docstring is its definition's documentation"
  (check-equal? '(((init) override) ((spell) define)) (fixtures:changes-of spell:dictionary-path))
  (check-equal? '(((init) "en-GB")) (options:settings spell:language))
  (check-equal? '(((init) 80) ((prog) 90)) (options:settings fill:column))
  (check-equal? '(advice override) (fixtures:change-kinds (plugins:configuration-owner)))
  (check-equal? "Saves the file at a path." (definition-documentation saver:save!)))

(test "the configuration's setting wins over a module's, and a module's is in effect where the configuration has none"
  (check-equal? '(80 "en-GB" 30) (list (fill:column) (spell:language) (saver:autosave-seconds)))
  (fixtures:write-lib-module! '(corfu) '((import (options)) (options:define-option auto-delay 0.2 real?) (options:set! auto-delay 0.3)))
  (check-equal? 0.3 (at-repl '(begin (import (corfu)) (corfu:auto-delay)))))

(test "the configuration's removal of a module's hook entry holds, and its mode hook sets local values that options:with binds over"
  (saver:save! "x")
  (check-equal? '((announce "x")) (fixtures:take-notes!))
  (let ([s (scopes:make)])
    (scopes:current s)
    (prog:mode)
    (check-equal? 100 (fill:column))
    (check-equal? 60 (options:with ([fill:column 60]) (fill:column)))
    (saver:save! "x")
    (check-equal? '((announce "x") indent) (fixtures:take-notes!))
    (scopes:current #f)))

(test "the configuration's advice stays when its target is redefined in its module"
  (eval-in-module '(define (save! path) (fixtures:note! 'saved) path) '(saver))
  (check-equal? "a" (saver:save! "a"))
  (check-equal? '((announce "a") saved) (fixtures:take-notes!)))

(test "advice added twice by one owner is added once, the last added outermost"
  (at-repl '(define (exclaim save! path) (fixtures:note! 'exclaim) (save! path)))
  (at-repl '(advice-add! saver:save! exclaim))
  (at-repl '(advice-add! saver:save! exclaim))
  (saver:save! "a")
  (check-equal? '(exclaim (announce "a") saved) (fixtures:take-notes!)))

(test "removing the configuration's advice at the REPL is the REPL's change, and a removal of one's own advice hides lower-ranked owners' too"
  (at-repl '(advice-remove! saver:save! announce))
  (check-equal? '(((repl) removal) ((repl) advice) ((init) advice) ((saver) define)) (fixtures:changes-of saver:save!))
  (saver:save! "b")
  (check-equal? '(exclaim saved) (fixtures:take-notes!))
  (at-repl '(advice-remove! saver:save! exclaim))
  (check-equal? '(removal removal) (fixtures:change-kinds (plugins:repl-owner)))
  (saver:save! "c")
  (check-equal? '(saved) (fixtures:take-notes!)))

(test "only a changeable procedure takes advice, and advice is a procedure"
  (check-equal? "not a changeable procedure" (fixtures:raised-message (lambda () (at-repl '(advice-add! car exclaim)))))
  (check-equal? "not a procedure" (fixtures:raised-message (lambda () (at-repl '(advice-add! saver:save! 'exclaim))))))

(test "eval-in-module's definition assigns it for the module, so a procedure held earlier calls the new one, with no change and the configuration's override still in effect"
  (at-repl '(define held spell:check))
  (eval-in-module '(define (check path) (fixtures:note! (list 'new-check path))) '(spell))
  (at-repl '(held "b.txt"))
  (check-equal? '((new-check "b.txt")) (fixtures:take-notes!))
  (check-equal? '(define define define) (fixtures:change-kinds (module-owner '(spell))))
  (check-equal? '(((init) override) ((spell) define)) (fixtures:changes-of spell:dictionary-path)))

(test "a new definition brings its own documentation"
  (eval-in-module '(define (save! path) "Saves quietly." path) '(saver))
  (check-equal? "Saves quietly." (definition-documentation saver:save!))
  (eval-in-module '(define (save! path) path) '(saver))
  (check-equal? #f (definition-documentation saver:save!)))

(test "reloading a module that defines hooks, options and tables keeps the entries, settings and table entries other owners made"
  (define (noted path) (fixtures:note! (list 'noted path)))
  (hooks:add! saver:after-save noted)
  (tables:set! saver:modes "rkt" 'racket)
  (reload-modules! '((saver)))
  (saver:save! "y")
  (check-equal? '((announce "y") (noted "y")) (fixtures:take-notes!))
  (check-equal? '(30 racket) (list (saver:autosave-seconds) (tables:ref saver:modes "rkt")))
  (hooks:remove! saver:after-save noted))

(test "unloading a module takes its procedures' local hook entries out of every scope, and the configuration's read loads a new instance"
  (let ([s1 (scopes:make)] [s2 (scopes:make)] [old (module-owner '(prog))])
    (scopes:current s1)
    (prog:mode)
    (scopes:current s2)
    (prog:mode)
    (saver:save! "x")
    (check-equal? '((announce "x") indent) (fixtures:take-notes!))
    (unload-owner! old)
    (saver:save! "x")
    (scopes:current s1)
    (saver:save! "x")
    (scopes:current #f)
    (check-equal? '((announce "x") (announce "x")) (fixtures:take-notes!))
    (check (not (owner-live? old)))
    (check (module-owner '(prog)))
    (check (not (eq? old (module-owner '(prog)))))))

(test "what other owners set in a module's options and tables is kept by name, so a new instance has it"
  (options:set! fill:column 81)
  (let ([old (module-owner '(fill))])
    (unload-owner! old)
    (check (not (owner-live? old)))
    (check-equal? 81 (fill:column))
    (check (assoc '(init) (options:settings fill:column))))
  (tables:set! saver:modes "rkt" 'racket)
  (let ([old (module-owner '(saver))])
    (unload-owner! old)
    (check (not (eq? old (module-owner '(saver)))))
    (check-equal? 'racket (tables:ref saver:modes "rkt" #f))))
