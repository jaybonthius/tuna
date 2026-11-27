(import (tuna) (test) (test-runner) (plugins) (fixtures))

(define (lib-file name) (fixtures:home-path ".config" "tuna" "lib" (string-append name ".sls")))
(define (raised form) (guard (c [(condition? c) c]) (fixtures:at-repl form) #f))
(define (raised-text form) (let ([c (raised form)]) (and c (fixtures:message c))))

(define (spell-forms folder version . extra)
  `((import (saver) (fixtures))
    (define (language) "en")
    (define (dictionary-path) (string-append ,folder (language)))
    (define %checked 0)
    (define (checked) %checked)
    (define (check path) (set! %checked (+ %checked 1)) (list path (dictionary-path)))
    (define (log-save save! path) (fixtures:note! 'spell) (save! path))
    ,@extra
    (define-syntax with-words (syntax-rules () [(_ e) (list ',version e)]))
    (advice-add! saver:save! log-save)))

(define (save path)
  (let ([saved (fixtures:at-repl `(saver:save! ,path))])
    (list saved (fixtures:take-notes!))))

(fixtures:write-lib-module! '(saver) '((define (save! path) path)))
(fixtures:write-lib-module! '(spell) (spell-forms "/usr/share/dict/" 'v1))
(fixtures:load-configuration!
  '((import (tuna) (saver) (fixtures))
    (load-module! '(spell))
    (define spell:dictionary-path (lambda () "/home/groucho/words"))
    (define (announce save! path) (fixtures:note! 'announce) (save! path))
    (advice-add! saver:save! announce)))

(test "a module's advice runs under the configuration's"
  (check-equal? '("a" (announce spell)) (save "a")))

(test "evaluating a module's file runs its definitions again, though the file is unchanged"
  (fixtures:at-repl '(spell:check "a"))
  (check-equal? 1 (fixtures:at-repl '(spell:checked)))
  (reload-modules! '((spell)))
  (check-equal? 0 (fixtures:at-repl '(spell:checked))))

(test "a removal of a module's advice is the remover's change, and stays when the module reloads and advises again"
  (fixtures:at-repl '(advice-remove! saver:save! spell:log-save))
  (check-equal? '("b" (announce)) (save "b"))
  (reload-modules! '((spell)))
  (check-equal? '("c" (announce)) (save "c"))
  (check-equal? '(((spell) advice) ((repl) removal) ((init) advice) ((saver) define)) (fixtures:changes-of saver:save!))
  (check (fixtures:at-repl '(eq? (caddr (car (definition-changes saver:save!))) spell:log-save)))
  (check-equal? "/home/groucho/words" (fixtures:at-repl '(spell:dictionary-path))))

(define loads '())
(define (note-load next owner) (set! loads (cons (owner-name owner) loads)) (next owner))

(test "a module that uses another's macro is compiled again when that module reloads with the macro changed, and loads after it"
  (fixtures:write-lib-module! '(speller) '((import (spell)) (define (go) (spell:with-words "z"))))
  (check-equal? '(v1 "z") (fixtures:at-repl '(begin (import (speller)) (speller:go))))
  (fixtures:at-repl '(define (use-words) (spell:with-words "q")))
  (fixtures:write-lib-module! '(spell) (spell-forms "/usr/share/words/" 'v2))
  (set! loads '())
  (advice-add! module-loaded note-load)
  (reload-modules! '((spell)))
  (advice-remove! module-loaded note-load)
  (check-equal? '((speller) (spell)) loads)
  (check-equal? '(v2 "z") (fixtures:at-repl '(speller:go))))

(test "a top-level form keeps its expansion until it is evaluated again"
  (check-equal? '(v1 "q") (fixtures:at-repl '(use-words)))
  (check-equal? "/home/groucho/words" (fixtures:at-repl '(spell:dictionary-path))))

(test "a version whose body raises raises, and the previous version loads again, its changes and its importers with it"
  (fixtures:write-lib-module! '(spell) (spell-forms "/usr/share/words/" 'v2 '(define broken (car '()))))
  (let ([kinds-before (fixtures:change-kinds (module-owner '(spell)))])
    (set! loads '())
    (advice-add! module-loaded note-load)
    (check-equal? 'car (condition-who (guard (c [#t c]) (reload-modules! '((spell))))))
    (advice-remove! module-loaded note-load)
    (check-equal? '((speller) (spell)) loads)
    (check-equal? '(v2 "z") (fixtures:at-repl '(speller:go)))
    (check-equal? kinds-before (fixtures:change-kinds (module-owner '(spell))))
    (check-equal? '("d" "/home/groucho/words") (fixtures:at-repl '(spell:check "d")))))

(test "so does a version that fails to compile, each time it is evaluated, until its file is fixed"
  (fixtures:write-lib-module! '(spell) (spell-forms "/usr/share/words/" 'v2 '(define (bad) (if))))
  (for-each
    (lambda (try)
      (check (syntax-violation? (guard (c [#t c]) (reload-modules! '((spell))))))
      (check-equal? '(v2 "z") (fixtures:at-repl '(speller:go))))
    '(1 2))
  (fixtures:write-lib-module! '(spell) (spell-forms "/usr/share/dict/" 'v3))
  (reload-modules! '((spell)))
  (check-equal? '(v3 "z") (fixtures:at-repl '(speller:go)))
  (check-equal? '("e" (announce)) (save "e")))

(test "reloading an importer alone leaves its import as it is"
  (let ([spell (module-owner '(spell))])
    (set! loads '())
    (advice-add! module-loaded note-load)
    (reload-modules! '((speller)))
    (advice-remove! module-loaded note-load)
    (check-equal? '((speller)) loads)
    (check-equal? spell (module-owner '(spell)))))

(test "a definition a module's running version no longer makes raises after a reload, by name or through a held procedure, and others' advice on it stays"
  (fixtures:write-lib-module! '(removed) '((define (f) 1) (define (g) 'g)))
  (fixtures:at-repl '(import (removed)))
  (fixtures:at-repl '(define held-g removed:g))
  (fixtures:at-repl '(advice-add! removed:g (lambda (g) (list 'advised (g)))))
  (check-equal? '(advised g) (fixtures:at-repl '(removed:g)))
  (fixtures:write-lib-module! '(removed) '((define (f) 3)))
  (reload-modules! '((removed)))
  (check-equal? 3 (fixtures:at-repl '(removed:f)))
  (check-equal? "module (removed) no longer defines it" (raised-text '(removed:g)))
  (check-equal? "module (removed) no longer defines it" (raised-text '(held-g)))
  (fixtures:at-repl '(define removed:g (lambda () 'set)))
  (check-equal? '(define) (fixtures:change-kinds (module-owner '(removed))))
  (check-equal? '(advice removal) (fixtures:change-kinds (plugins:repl-owner))))

(test "defining it again brings it back, under the advice"
  (fixtures:write-lib-module! '(removed) '((define (f) 1) (define (g) 'g)))
  (reload-modules! '((removed)))
  (check-equal? '(advised g) (fixtures:at-repl '(removed:g)))
  (check-equal? '(advised g) (fixtures:at-repl '(held-g))))

(test "a definition made only by a version whose body raised goes when the previous version loads again"
  (fixtures:write-lib-module! '(removed) '((define (f) 2) (define (g) 'g) (define (extra) 'extra) (car '())))
  (check-equal? 'car (condition-who (guard (c [#t c]) (reload-modules! '((removed))))))
  (check-equal? 1 (fixtures:at-repl '(removed:f)))
  (check-equal? '(define define) (fixtures:change-kinds (module-owner '(removed)))))

(test "unloading a module unloads its importers first, running their unload actions"
  (fixtures:write-lib-module! '(speller) '((import (spell) (fixtures)) (define (go) (spell:check "z")) (on-unload (lambda () (fixtures:note! 'speller-unloaded)))))
  (reload-modules! '((speller)))
  (fixtures:take-notes!)
  (fixtures:at-repl '(define held spell:check))
  (unload-owner! (module-owner '(spell)))
  (check-equal? '(speller-unloaded) (fixtures:take-notes!))
  (check-equal? '(#f #f) (map module-owner '((spell) (speller)))))

(test "an unloaded module's names raise, by name or through a held procedure, and other owners' changes stay on its names"
  (for-each
    (lambda (form name) (check-equal? (format "module ~s is unloaded" name) (raised-text form)))
    '((spell:check "a") (held "a") (spell:checked) (speller:go))
    '((spell) (spell) (spell) (speller)))
  (check-equal? '(advice override) (fixtures:change-kinds (plugins:configuration-owner)))
  (check-equal? '(((repl) removal) ((init) advice) ((saver) define)) (fixtures:changes-of saver:save!))
  (check-equal? '("a" (announce)) (save "a")))

(test "an unloaded module is not an owner any more"
  (check-equal? "not an owner" (fixtures:raised-message (lambda () (call-as-owner (module-owner '(spell)) (lambda () 1)))))
  (check-equal? "not a loaded module" (fixtures:raised-message (lambda () (eval-in-module '(language) '(spell)))))
  (check-equal? "not an owner" (fixtures:raised-message (lambda () (unload-owner! (module-owner '(spell)))))))

(test "loaded again, a module is a new instance whose body runs, and others' overrides and held procedures reach it"
  (set! loads '())
  (advice-add! module-loaded note-load)
  (let ([o (load-module! '(spell))])
    (check-equal? '((spell)) loads)
    (check-equal? "/home/groucho/words" (fixtures:at-repl '(spell:dictionary-path)))
    (check-equal? '("b" "/home/groucho/words") (fixtures:at-repl '(held "b")))
    (check-equal? o (load-module! '(spell)))
    (check-equal? '((spell)) loads))
  (advice-remove! module-loaded note-load))

(test "an importer stays unloaded until it is loaded again"
  (check-equal? "module (speller) is unloaded" (raised-text '(speller:go)))
  (load-module! '(speller))
  (check-equal? '("z" "/home/groucho/words") (fixtures:at-repl '(speller:go))))

(test "unloading an internal module unloads its importers and shadows every one of its names, while a procedure taken from a name that is not changeable still runs"
  (fixtures:write-lib-module! '(magit) '((import (magit git)) (define (status) (magit/git:run))))
  (fixtures:write-lib-module! '(magit git) '((define-record-type thing (fields a)) (define version 1) (define (run) 'git-default)))
  (fixtures:at-repl '(import (magit)))
  (fixtures:at-repl '(define make magit/git:make-thing))
  (unload-owner! (module-owner '(magit git)))
  (check-equal? '("module (magit git) is unloaded" "module (magit git) is unloaded" "module (magit git) is unloaded" "module (magit) is unloaded")
    (map raised-text '((magit/git:run) magit/git:make-thing magit/git:version (magit:status))))
  (check (fixtures:at-repl '(record? (make 5)))))

(test "loading an importer loads its unloaded import too, and rebinds the names of both"
  (load-module! '(magit))
  (check-equal? '(1 git-default git-default) (fixtures:at-repl '(list magit/git:version (magit/git:run) (magit:status)))))

(test "a changeable definition called within the form that unloads it raises"
  (check-equal? "module (magit) is unloaded" (raised-text '(begin (unload-owner! (module-owner '(magit git))) (magit:status)))))

(test "unloading a module the configuration imports reads the configuration again, which loads a new instance with its advice"
  (unload-owner! (module-owner '(saver)))
  (check (module-owner '(saver)))
  (check-equal? '(speller-unloaded) (fixtures:take-notes!))
  (check-equal? '("x" (announce)) (save "x"))
  (check-equal? '(advice override) (fixtures:change-kinds (plugins:configuration-owner)))
  (load-module! '(spell))
  (check-equal? '("y" (announce)) (save "y")))

(test "load-module! and module-owner refuse what is not a module"
  (for-each
    (lambda (name) (check-equal? "not a module" (fixtures:raised-message (lambda () (load-module! name)))))
    '((nothere) (tuna) (chezscheme) (init)))
  (check-equal? "not a module name" (fixtures:raised-message (lambda () (module-owner 'spell)))))

(test "unload actions run newest first, and one that raises is reported while the rest run"
  (fixtures:write-lib-module! '(actor)
    '((import (fixtures))
      (on-unload (lambda () (fixtures:note! 'first)))
      (on-unload (lambda () (error 'second "failed")))
      (on-unload (lambda () (fixtures:note! 'third)))))
  (load-module! '(actor))
  (check-equal? '(second) (map condition-who (fixtures:reports-during (lambda () (unload-owner! (module-owner '(actor)))))))
  (check-equal? '(third first) (fixtures:take-notes!)))

(test "a module whose body raises on its first load is unloaded: the import raises, then its unload actions run and its changes are taken back"
  (fixtures:write-lib-module! '(boom)
    '((import (saver) (fixtures))
      (define (x) 1)
      (override-set! saver:save! (lambda (path) 'boom))
      (on-unload (lambda () (fixtures:note! 'boom-unloaded)))
      (car '())))
  (check-equal? 'car (condition-who (raised '(import (boom)))))
  (test-runner:wait-until (lambda () (not (module-owner '(boom)))))
  (check-equal? '(boom-unloaded) (fixtures:take-notes!))
  (check-equal? '("a" (announce)) (save "a"))
  (check (assertion-violation? (raised '(boom:x)))))

(test "a module whose import raises on its first load is unloaded too, each time it is loaded"
  (fixtures:write-lib-module! '(outer) '((import (boom)) (define (y) (boom:x))))
  (for-each
    (lambda (form)
      (check-equal? 'car (condition-who (raised form)))
      (test-runner:wait-until (lambda () (not (or (module-owner '(outer)) (module-owner '(boom)))))))
    '((import (outer)) (load-module! '(outer))))
  (check-equal? '(boom-unloaded boom-unloaded) (fixtures:take-notes!))
  (check (assertion-violation? (raised '(outer:y)))))

(test "a module whose first load failed reads its saved file when it is imported again"
  (fixtures:write-lib-module! '(fizzle) '((import (saver)) (define (x) 1) (car '())))
  (check-equal? 'car (condition-who (raised '(import (fizzle)))))
  (test-runner:wait-until (lambda () (not (module-owner '(fizzle)))))
  (fixtures:write-lib-module! '(fizzle) '((import (saver)) (define (x) 2)))
  (check-equal? 2 (fixtures:at-repl '(begin (import (fizzle)) (fizzle:x)))))

(test "an unloaded importer is left alone when a module it imported reloads or loads again, so it may no longer compile, or its file may be gone"
  (fixtures:write-lib-module! '(base) '((import (fixtures)) (define (f) 1) (define (g) 'g) (on-unload (lambda () (fixtures:note! 'base-unloaded)))))
  (fixtures:write-lib-module! '(user) '((import (base)) (define (h) (list (base:f) (base:g)))))
  (check-equal? '(1 g) (fixtures:at-repl '(begin (import (user)) (user:h))))
  (unload-owner! (module-owner '(user)))
  (fixtures:write-lib-module! '(base) '((import (fixtures)) (define (f) 2) (on-unload (lambda () (fixtures:note! 'base-unloaded)))))
  (reload-modules! '((base)))
  (check-equal? '(base-unloaded) (fixtures:take-notes!))
  (check-equal? 2 (fixtures:at-repl '(base:f)))
  (check (syntax-violation? (guard (c [#t c]) (load-module! '(user)))))
  (check-equal? "module (user) is unloaded" (raised-text '(user:h)))
  (fixtures:write-lib-module! '(user) '((import (base)) (define (h) (list (base:f)))))
  (load-module! '(user))
  (check-equal? '(2) (fixtures:at-repl '(user:h)))
  (unload-owner! (module-owner '(user)))
  (delete-file (lib-file "user"))
  (reload-modules! '((base)))
  (unload-owner! (module-owner '(base)))
  (load-module! '(base))
  (check-equal? 2 (fixtures:at-repl '(base:f)))
  (fixtures:take-notes!))

(test "a module importing another and one of its importers is unloaded once"
  (fixtures:write-lib-module! '(user) '((import (base)) (define (h) (list (base:f)))))
  (fixtures:write-lib-module! '(diamond) '((import (base) (user) (fixtures)) (on-unload (lambda () (fixtures:note! 'diamond-unloaded)))))
  (fixtures:at-repl '(import (diamond)))
  (unload-owner! (module-owner '(base)))
  (check-equal? '(diamond-unloaded base-unloaded) (fixtures:take-notes!))
  (check-equal? #f (module-owner '(diamond))))
