(import (tuna) (test) (test-runner) (plugins) (fixtures))

(define (lib-file name) (fixtures:home-path ".config" "tuna" "lib" (string-append name ".sls")))
(define plugins-folder (fixtures:home-path ".local" "share" "tuna" "plugins"))
(define (raised form) (guard (c [(condition? c) c]) (fixtures:at-repl form) #f))
(define (raised-text form)
  (let ([c (raised form)]) (and c (list (and (who-condition? c) (condition-who c)) (fixtures:message c)))))

(define (write-plugin-module! id name forms)
  (fixtures:write-module! (string-append plugins-folder "/" id "/src") name forms))

(fixtures:write-lib-module! '(shadowed) '((define (where) "lib/")))
(write-plugin-module! "shadowed" '(shadowed) '((define (where) "the plugin")))
(write-plugin-module! "other" '(other) '((define (name) 'other)))
(write-plugin-module! "command-line" '(command-line) '((define (where) "the plugin")))
(fixtures:write-lib-module! '(tuna other) '((define (where) "lib/")))
(fixtures:write-lib-module! '(tuna extra) '((define (where) "lib/")))
(fixtures:write-lib-module! '(lang extra) '((define (where) "lib/")))
(fixtures:write-lib-module! '(jobs-test words) '((define (where) "lib/")))

(define start-reports
  (test-runner:reports-during (lambda () (fixtures:load-configuration! '((import (tuna)))))))

(test "a module in lib/ that replaces an installed plugin's is reported when the configuration is read"
  (check-equal? (list (format "(shadowed) in lib/ replaces ~a/shadowed/src/shadowed.sls" plugins-folder))
    (map fixtures:message start-reports)))

(test "a module is looked for in lib/, then in the installed plugins, then in Tuna's own plugins"
  (check-equal? "lib/" (fixtures:at-repl '(begin (import (shadowed)) (shadowed:where))))
  (check-equal? 'other (fixtures:at-repl '(begin (import (other)) (other:name))))
  (check-equal? "the plugin" (fixtures:at-repl '(begin (import (command-line)) (command-line:where))))
  (check-equal? 'tuna (plugins:module-source '(command-line handled))))

(test "a module (x-test ...) is looked for in lib/, then in the tests/lib/ of Tuna's own plugin x"
  (check-equal? #t (fixtures:at-repl '(begin (import (design-tokens-test css)) (design-tokens-test/css:prefix? "a" "ab"))))
  (check-equal? 'tuna (plugins:module-source '(design-tokens-test css)))
  (check-equal? "lib/" (fixtures:at-repl '(begin (import (jobs-test words)) (jobs-test/words:where))))
  (check-equal? 'user (plugins:module-source '(jobs-test words))))

(test "Tuna's own names resolve only to Tuna's own libraries"
  (for-each
    (lambda (form) (check-equal? '(load-module! "not a module") (raised-text form)))
    '((import (tuna extra)) (import (only (tuna other) where)) (import (only (lang extra) where)))))

(test "the owners' names, and names that would replace Chez's own, are not module names"
  (check-equal? '("library (init) not found" "library (repl) not found")
    (map (lambda (form) (cadr (raised-text form))) '((import (init)) (import (repl)))))
  (check-equal? '((import "a module cannot be named (csv7 tools)") (import "a module cannot be named (r6rs)"))
    (map raised-text '((import (csv7 tools)) (import (r6rs))))))

(test "a module is named by its path under a library root, and an import gives its names with its prefix, parts joined by /"
  (fixtures:write-lib-module! '(greet) '((define (text name) (string-append "Hello, " name "!")) (define (module-name) (this-module))))
  (fixtures:write-lib-module! '(greet util) '((define (user-name) "Groucho")))
  (check-equal? '("Hello, Harpo!" (greet) "Groucho")
    (fixtures:at-repl '(begin (import (greet) (greet util)) (list (greet:text "Harpo") (greet:module-name) (greet/util:user-name)))))
  (check-equal? (plugins:repl-owner) (fixtures:at-repl '(current-owner))))

(test "every caller uses the definition in effect, and a procedure's name gives the same procedure each time, printed without its name"
  (fixtures:at-repl '(define held greet:text))
  (check (fixtures:at-repl '(eq? held greet:text)))
  (fixtures:at-repl '(define greet:text (lambda (name) (string-append "Hi, " name))))
  (check-equal? '("Hi, Chico" "Hi, Chico") (fixtures:at-repl '(list (held "Chico") (greet:text "Chico"))))
  (check-equal? -1 (fixtures:at-repl '(procedure-arity-mask held)))
  (check-equal? "#<procedure>" (format "~s" (fixtures:at-repl 'held))))

(test "outside a module, define-public is Chez's define"
  (fixtures:at-repl '(define-public (outside) 'plain))
  (check-equal? 'plain (fixtures:at-repl '(outside)))
  (check-equal? '(definition-changes "not a changeable procedure") (raised-text '(definition-changes outside))))

(test "a module whose body raises leaves the owner as it was, so the next change is the REPL's"
  (fixtures:write-lib-module! '(boom) '((define (x) 1) (error 'boom "failed")))
  (check-equal? '(boom "failed") (raised-text '(import (boom))))
  (check-equal? (plugins:repl-owner) (fixtures:at-repl '(current-owner)))
  (fixtures:at-repl '(define greet/util:user-name (lambda () "Zeppo")))
  (check-equal? '(((repl) override) ((greet util) define)) (fixtures:changes-of greet/util:user-name)))

(test "a define of a name an import earlier in the same form binds is an override, though the module has not run when the form is checked"
  (fixtures:write-lib-module! '(fresh) '((define (y) 1)))
  (check-equal? 2 (fixtures:at-repl '(begin (import (fresh)) (define fresh:y (lambda () 2)) (fresh:y)))))

(test "a module may define a name #!tuna provides; its own code means its definition, and other code sees it prefixed"
  (fixtures:write-lib-module! '(lists)
    '((import (rename (only (chezscheme) map) (map chez:map)))
      (define (map f xs) (list 'mine))
      (define (twice xs) (map car xs))
      (define (both xs) (list (map car xs) (chez:map - xs)))))
  (check-equal? '((mine) (mine) (-1) ((mine) (-1 -2)))
    (fixtures:at-repl '(begin (import (lists)) (list (lists:twice '(1)) (lists:map car '(1)) (map - '(1)) (lists:both '(1 2)))))))

(test "a module cannot define a keyword its own code uses"
  (fixtures:write-lib-module! '(redefine) '((define (define x) x) (define (g) 1)))
  (let ([c (raised '(import (redefine)))])
    (check (syntax-violation? c))
    (check-equal? (list (lib-file "redefine") 3 10) (fixtures:reported-position c))))

(fixtures:write-lib-module! '(macros)
  '((import (options))
    (define-syntax define-command (syntax-rules () [(_ (n . f) b ...) (define-public (n . f) b ...)]))
    (define-syntax define-point (syntax-rules () [(_ n) (define-record-type n (fields x))]))
    (define-syntax define-flag (syntax-rules () [(_ n) (options:define-option n #f boolean?)]))
    (define-syntax def-const (syntax-rules () [(_ n v) (define n v)]))
    (define-flag verbose)
    (define-command (hello) "hello")
    (define-point pt)
    (def-const limit 10)
    (define-public (greeting) "hi")
    (define-record-type entry (fields key))
    (define-values (low high) (values 1 9))
    (define (origin) (list (pt-x (make-pt 0)) limit))))
(fixtures:at-repl '(import (macros)))

(test "define-public and macros on it export their names, Chez's definition forms export theirs at a module's top level, and a name a macro defines with them stays inside"
  (check-equal? '("hi" "hello" k (1 9) (0 10) #f)
    (fixtures:at-repl '(list (macros:greeting) (macros:hello) (macros:entry-key (macros:make-entry 'k)) (list macros:low macros:high)
                             (macros:origin) (macros:verbose))))
  (fixtures:at-repl '(define macros:hello (lambda () "hi")))
  (check-equal? '(((repl) override) ((macros) define)) (fixtures:changes-of macros:hello))
  (for-each
    (lambda (name) (check (assertion-violation? (raised name))))
    '(macros:make-pt macros:limit)))

(test "a module's value cannot be defined again, an override is a procedure, and only a module's procedures are changeable"
  (check-equal? '(define "macros:low is (macros)'s definition and cannot be defined again") (raised-text '(define macros:low 2)))
  (check-equal? '(override-set! "not a procedure") (raised-text '(define macros:verbose 2)))
  (check-equal? '(advice-add! "not a changeable procedure")
    (raised-text '(advice-add! macros:make-entry (lambda (make . arguments) (apply make arguments))))))

(test "Chez's other definition forms cannot define a module's name again, and a changeable procedure's refusal says define overrides it"
  (check-equal?
    '((define-values "macros:low is (macros)'s definition and cannot be defined again")
      (define-values "macros:hello is (macros)'s changeable procedure; override it with define")
      (define-syntax "macros:define-command is (macros)'s definition and cannot be defined again")
      (define-record-type "macros:entry is (macros)'s definition and cannot be defined again")
      (define-record "macros:entry is (macros)'s definition and cannot be defined again")
      (alias "macros:high is (macros)'s definition and cannot be defined again")
      (define-syntax "macros:high is (macros)'s definition and cannot be defined again")
      (define-values "macros:low is (macros)'s definition and cannot be defined again"))
    (map raised-text
         '((define-values (macros:low) (values 2))
           (define-values (fresh-value macros:hello) (values 1 (lambda () "hi")))
           (define-syntax macros:define-command (syntax-rules () [(_) 1]))
           (define-record-type macros:entry (fields a))
           (define-record macros:entry (a))
           (alias macros:high car)
           (meta define-syntax macros:high (syntax-rules () [(_) 1]))
           (let () (define-values (macros:low) (values 7)) macros:low))))
  (check-equal? '(1 9 k #t "hi")
    (fixtures:at-repl '(list macros:low macros:high (macros:entry-key (macros:make-entry 'k)) (macros:entry? (macros:make-entry 'k)) (macros:hello))))
  (check-equal? '(2 1) (fixtures:at-repl '(begin (define-values (fresh-value macros-free) (values 2 1)) (list fresh-value macros-free)))))

(test "a property needs the identifier it is keyed by"
  (fixtures:write-lib-module! '(nodefiner) '((define (d) 1) (define-property d definer #t)))
  (let ([c (raised '(import (nodefiner)))])
    (check (syntax-violation? c))
    (check-equal? (list (lib-file "nodefiner") 3 20) (fixtures:reported-position c))))

(test "a definition after an expression is refused, naming the module's file, whether the module is imported or compiled for an importer"
  (fixtures:write-lib-module! '(late) '((display "") (define (f) 1)))
  (fixtures:write-lib-module! '(useslate) '((import (late)) (define (g) (late:f))))
  (check-equal? (lib-file "late") (condition-who (raised '(import (late)))))
  (check-equal? (lib-file "late") (condition-who (raised '(import (useslate))))))

(test "a module's sleep pauses a thread's task and refuses to block the main thread, and a module may define its own sleep and exit"
  (fixtures:write-lib-module! '(sleeper) '((define (nap) (sleep (make-time 'time-duration 0 0)) 'woke)))
  (fixtures:write-lib-module! '(shadows) '((define (sleep seconds) (list 'slept seconds)) (define (exit) 'stayed) (define (both) (list (sleep 1) (exit)))))
  (fixtures:at-repl '(import (sleeper)))
  (check-equal? '(returned (woke))
    (call-with-values (lambda () (join-task (fork-task (lambda (restore) (fixtures:at-repl '(sleeper:nap)))))) list))
  (check-equal? "would block the main thread; pause a task instead" (fixtures:raised-message (lambda () (fixtures:at-repl '(sleeper:nap)))))
  (check-equal? '((slept 1) stayed) (fixtures:at-repl '(begin (import (shadows)) (shadows:both)))))

(test "a module's own set! assigns its variable from any thread, and it exports a reader, since an assigned variable is not exported"
  (fixtures:write-lib-module! '(assign) '((define %count 0) (define (count) %count) (define (bump!) (set! %count (+ %count 1)) %count)))
  (check-equal? '(1 2 2) (fixtures:at-repl '(begin (import (assign)) (let* ([a (assign:bump!)] [b (assign:bump!)]) (list a b (assign:count))))))
  (join-task (fork-task (lambda (restore) (fixtures:at-repl '(assign:bump!)))))
  (check-equal? 3 (fixtures:at-repl '(assign:count))))

(fixtures:write-lib-module! '(scoped)
  '((module helpers (twice) (define (twice x) (* 2 x)))
    (import helpers)
    (module counter (n bump!) (define n 0) (define (bump!) (set! n (+ n 1))))
    (import counter)
    (define (count) (bump!) n)
    (define (text) "scoped")))
(fixtures:at-repl '(import (scoped)))

(test "each module exports its prefix's %scope, and eval-in-module sees what a Chez module form in its body gives, not a variable such a form assigns"
  (check (memq 'scoped:%scope (library-exports '(scoped))))
  (check-equal? 8 (eval-in-module '(twice 4) '(scoped)))
  (check-equal? 1 (fixtures:at-repl '(scoped:count)))
  (check-equal? "attempt to reference assigned hence unexported library variable"
    (guard (c [(syntax-violation? c) (condition-message c)]) (eval-in-module 'n '(scoped)))))

(test "eval-in-module's define of a module's procedure redefines it for the module, which is no change; a set! of it, or a define of a value or a new name, raises"
  (eval-in-module '(define (text) "assigned") '(scoped))
  (check-equal? "assigned" (fixtures:at-repl '(scoped:text)))
  (check-equal? "attempt to assign immutable variable"
    (guard (c [(syntax-violation? c) (condition-message c)]) (eval-in-module '(set! text (lambda () "set")) '(scoped))))
  (check-equal? "assigned" (fixtures:at-repl '(scoped:text)))
  (check-equal? '(((scoped) define)) (fixtures:changes-of scoped:text))
  (check-equal? "(scoped) has no procedure fresh to redefine; values and new names change by reloading"
    (fixtures:raised-message (lambda () (eval-in-module '(define fresh 1) '(scoped)))))
  (check-equal? "the new value of scoped:text is not a procedure; values change by reloading (scoped)"
    (fixtures:raised-message (lambda () (eval-in-module '(define text 5) '(scoped)))))
  (check-equal? (list "invalid definition in immutable environment")
    (guard (c [(syntax-violation? c) (list (condition-message c))]) (eval-in-module '(define-syntax y (syntax-rules () [(_) 1])) '(scoped)))))

(test "eval-in-module names the module the code runs in, and refuses a module that is not loaded"
  (check-equal? '(scoped) (eval-in-module '(this-module) '(scoped)))
  (unload-owner! (module-owner '(greet)))
  (check-equal? '(eval-in-module "not a loaded module")
    (guard (c [#t (list (condition-who c) (fixtures:message c))]) (eval-in-module '(text) '(greet)))))

(test "a tool advises a name chosen at run time, through a procedure it takes from the module's scope, as its own change"
  (fixtures:write-lib-module! '(tool)
    '((define %self (current-owner))
      (define (run module name proc)
        (call-as-owner %self (lambda () ((eval-in-module `(lambda (p) (advice-add! ,name p)) module) proc))))))
  (fixtures:at-repl '(import (tool)))
  (fixtures:at-repl '(tool:run '(scoped) 'text (lambda (text) (list (text)))))
  (check-equal? '("assigned") (fixtures:at-repl '(scoped:text)))
  (check-equal? '(advice define) (map car (owner-changes (module-owner '(tool))))))

(test "a module cannot define %scope"
  (fixtures:write-lib-module! '(rescope) '((define (%scope) 1)))
  (check-equal? "multiple definitions for %scope in body"
    (guard (c [(syntax-violation? c) (condition-message c)]) (fixtures:at-repl '(import (rescope))))))
