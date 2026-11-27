(import (tuna) (test) (test-runner) (buffers) (document) (files) (syntax-highlighting) (chez-scheme) (chez-scheme-test scheme-buffers))

;; Loaded, not imported, so the tests' unloads of them stay unloads.
(chez-scheme-test/scheme-buffers:write-lib-modules!)
(load-module! '(zeppo))
(load-module! '(tunes))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

;; A buffer's names come from the scope its job finds, after which the job
;; highlights again with them; text added after that is lexed with the
;; names, so once it shows, every face is final.
(define (final-faces b scoped?)
  (when scoped?
    (test-runner:wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names))))))
  (let ([end (- (document:length (buffers:document b)) 1)])
    (buffers:replace! b end end " 7"))
  (test-runner:wait-until (lambda () (eq? 'number (chez-scheme-test/scheme-buffers:face-of b "7"))))
  (chez-scheme-test/scheme-buffers:faces b))

(define (word-faces content scoped? . words)
  (let* ([b (chez-scheme-test/scheme-buffers:scheme-buffer "names.ss" content)] [faces (final-faces b scoped?)])
    (buffers:kill! b)
    (map (lambda (word) (let ([found (assoc word faces)]) (and found (cadr found)))) words)))

(define (described b spellings)
  (map (lambda (s)
         (let ([n (chez-scheme:find-name b s)])
           (and n (list (chez-scheme:name-export n) (chez-scheme:name-library n) (chez-scheme:name-kind n)))))
       spellings))

(test "#!tuna gives a module's scope, (chezscheme) and (tuna), after its own imports"
  (check-equal? '(keyword function.builtin #f)
                (word-faces "#!tuna\n(import (options))\n(options:define-option x 1 number?) (car 1) (buffers:make)" #t
                            "options:define-option" "car" "buffers:make"))
  (check-equal? '(#f keyword function.builtin)
                (word-faces "#!tuna\n(options:define-option x 1 number?) (define-public (y) (owner-changes 1))" #t
                            "options:define-option" "define-public" "owner-changes")))

(test "import forms give their specs, with only, except, prefix, rename, library and for"
  (check-equal? '(function.builtin #f function.builtin function.builtin keyword)
                (word-faces "(import (only (rnrs) car) (prefix (buffers) b/) (rename (chezscheme) (cdr tail)))\n(car cdr tail b/buffers:make b/buffers:with-buffer)" #t
                            "car" "cdr" "tail" "b/buffers:make" "b/buffers:with-buffer"))
  (check-equal? '(#f function.builtin function.builtin #f)
                (word-faces "(import (except (chezscheme) car) (for (only (modes) modes:ancestry) run))\n(car cdr modes:ancestry modes:lighter)" #t
                            "car" "cdr" "modes:ancestry" "modes:lighter"))
  (check-equal? '(function.builtin #f)
                (word-faces "(import (library (chezscheme)))\n(car buffers:make)" #t "car" "buffers:make")))

(test "use-plugin lines give the plugin's main module, and a configuration also has the REPL's scope"
  (check-equal? '(function.builtin function.builtin)
                (word-faces "(use-plugin modes)\n(modes:ancestry buffers:make)" #t "modes:ancestry" "buffers:make"))
  (check-equal? '(keyword function.builtin keyword)
                (word-faces "(import (tuna))\n(use-plugin modes)\n(define (f x) (car (list x)))\n(options:define-option o 1 number?)" #t
                            "define" "car" "options:define-option")))

(test "data the reader makes that is not a spec is left out of the scope, and the job goes on"
  (let ([bad (chez-scheme-test/scheme-buffers:scheme-buffer "bad.ss" "(import #&x (chezscheme) #vfx(1) #0=(a . #0#))\n(car 1)")])
    (check-equal? 'function.builtin (cadr (assoc "car" (final-faces bad #t))))
    (buffers:replace! bad (chez-scheme-test/scheme-buffers:after bad "(car 1)") (chez-scheme-test/scheme-buffers:after bad "(car 1)") " (cdr 2)")
    (test-runner:wait-until (lambda () (eq? 'function.builtin (chez-scheme-test/scheme-buffers:face-of bad "cdr"))))
    (buffers:kill! bad))
  (check-equal? '(function.builtin) (word-faces "(library (a #!eof) (export) (import (chezscheme)))\n(car 1)" #t "car")))

(test "with none of these, the REPL's scope: procedures and hooks are drawn as procedures, tables and other values not at all, macros as syntax, and a helper as any other procedure"
  (check-equal? '(function.builtin keyword function.builtin function.builtin #f #f keyword function.builtin keyword)
                (word-faces "(car options:define-option modes:ancestry modes:major-mode-changed syntax:lexers faces:comment buffers:with-buffer chez-scheme:%highlight-input syntax:class)" #f
                            "car" "options:define-option" "modes:ancestry" "modes:major-mode-changed" "syntax:lexers" "faces:comment"
                            "buffers:with-buffer" "chez-scheme:%highlight-input" "syntax:class")))

(define zeppo (files:visit (chez-scheme-test/scheme-buffers:home-file ".config/tuna/lib/zeppo.sls")))

(define tunes (files:visit (chez-scheme-test/scheme-buffers:home-file ".config/tuna/lib/tunes.sls")))

(test "a module's file, found by its path, spells its own exports without the prefix, and its helpers are drawn there"
  (let ([faces (final-faces tunes #t)])
    (check-equal? '("hum" function) (assoc "hum" faces))
    (check-equal? '("%note" function.builtin) (assoc "%note" faces))))

(test "a library form names the file's own library; in another module's file an import's helper is no name"
  (check-equal? '(#f keyword) (word-faces "(library (zeppo) (export sing) (import (chezscheme)))\n(zeppo:sing define-syntax)" #t "zeppo:sing" "define-syntax"))
  (check-equal? '(#f function.builtin) (word-faces "#!tuna\n(import (tunes))\n(tunes:%note tunes:hum)" #t "tunes:%note" "tunes:hum")))

(test "a library the running Tuna has not loaded adds no names"
  (check-equal? '(#f #f) (word-faces "(import (nowhere))\n(nowhere:thing car)" #t "nowhere:thing" "car")))

(define hums (chez-scheme-test/scheme-buffers:scheme-buffer "hums.ss" "(import (tunes))\n(tunes:hum)"))

(test "when a module unloads, the buffers that import it lose its names and their colours; loading it again brings them back"
  (test-runner:wait-until (lambda () (eq? 'function.builtin (chez-scheme-test/scheme-buffers:face-of hums "tunes:hum"))))
  (unload-owner! (module-owner '(tunes)))
  (test-runner:wait-until (lambda () (not (chez-scheme-test/scheme-buffers:face-of hums "tunes:hum"))))
  (check-equal? #f (chez-scheme:find-name hums 'tunes:hum)))

(load-module! '(tunes))

(test "a module loaded again gives its names and colours back"
  (test-runner:wait-until (lambda () (eq? 'function.builtin (chez-scheme-test/scheme-buffers:face-of hums "tunes:hum")))))

(test "a module's names are classified again when it loads again, and the buffers whose scope holds it are highlighted again"
  (chez-scheme-test/scheme-buffers:write-text! ".config/tuna/lib/tunes.sls" "#!tuna\n(define (hum) (%note 1))\n(define (%note n) n)\n(define (sing) 1)\n")
  (let ([singer (chez-scheme-test/scheme-buffers:scheme-buffer "singer.ss" "(import (tunes))\n(tunes:sing)")])
    (final-faces singer #t)
    (check-equal? #f (chez-scheme-test/scheme-buffers:face-of singer "tunes:sing"))
    (reload-modules! '((tunes)))
    (test-runner:wait-until (lambda () (eq? 'function.builtin (chez-scheme-test/scheme-buffers:face-of singer "tunes:sing"))))))

(define plugins (string-append (path-parent (car (command-line))) "/plugins"))

(define bs (files:visit (string-append plugins "/buffers/src/buffers.sls")))

(test "each name a module's file sees is its spelling, the export it refers to, that export's library and its kind"
  (final-faces bs #t)
  (check-equal? '((buffers:insert! (buffers) procedure) (document:text (document) procedure) #f)
                (described bs '(insert! document:text buffers:insert!))))

(test "a module's file is offered its own helpers, not its imports'; its body imports (tuna core replaced) ahead of its first line's libraries"
  (final-faces zeppo #t)
  (check-equal? '((zeppo:%tune (zeppo) procedure) (zeppo:sing (zeppo) procedure) (zeppo:volume (zeppo) variable)
                  (spawn-task (tuna) procedure) (buffers:insert! (buffers) procedure) #f)
                (described zeppo '(%tune sing volume spawn-task buffers:insert! buffers:%replace)))
  (check-equal? '((sleep (tuna core replaced) procedure) (dynamic-wind (tuna core replaced) procedure) (car (chezscheme) procedure))
                (described zeppo '(sleep dynamic-wind car))))

(define plain (buffers:make "plain" ""))

(test "a buffer with no scope of its own sees the REPL's names: every export of the REPL's libraries, helpers included, the first library's for a name two export, and no module's %scope"
  (check (eq? (chez-scheme:repl-names) (chez-scheme:names plain)))
  (check-equal? '((sleep (tuna core replaced) procedure) (dynamic-wind (tuna core replaced) procedure) (car (chezscheme) procedure)
                  (zeppo:%tune (zeppo) procedure) (zeppo:volume (zeppo) variable) #f)
                (described plain '(sleep dynamic-wind car zeppo:%tune zeppo:volume zeppo:%scope)))
  (check-equal? 1 (length (filter (lambda (n) (eq? 'dynamic-wind (chez-scheme:name-spelling n))) (vector->list (chez-scheme:repl-names)))))
  (check (for-all chez-scheme:name? (vector->list (chez-scheme:repl-names)))))

(test "the REPL's libraries are (tuna core replaced), (chezscheme) and (tuna), the others Chez has loaded, then each loaded module"
  (let ([libraries (chez-scheme:tuna-libraries)])
    (check-equal? '((tuna core replaced) (chezscheme) (tuna)) (list-head libraries 3))
    (check (member '(zeppo) libraries))))

(test "a configuration gets its own imports' names, then the REPL's"
  (let ([config (chez-scheme-test/scheme-buffers:scheme-buffer "init.ss" "(import (tuna) (document))\n(use-plugin buffers)\n")])
    (final-faces config #t)
    (check-equal? '((zeppo:%tune (zeppo) procedure) (document:text (document) procedure) (spawn-task (tuna) procedure))
                  (described config '(zeppo:%tune document:text spawn-task)))))

(test "kinds are an enumeration"
  (check-equal? 'variable (chez-scheme:binding-kind variable)))

(test "an unloaded module's names go from the REPL's"
  (unload-owner! (module-owner '(zeppo)))
  (check-equal? '(#f) (described plain '(zeppo:sing))))

(load-module! '(zeppo))

(test "a module loaded again is in the REPL's names again"
  (check-equal? '((zeppo:sing (zeppo) procedure)) (described plain '(zeppo:sing))))

(test "arguments are checked"
  (check-raises (raised? 'chez-scheme:names "not a buffer") (chez-scheme:names 'plain))
  (check-raises (raised? 'chez-scheme:find-name "not a symbol") (chez-scheme:find-name plain "car")))
