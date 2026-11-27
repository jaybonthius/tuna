(import (tuna) (test) (hooks) (tables) (commands)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

;; A test appends to the module's file and reloads it, so it is the user's
;; own module, in lib/: a copy of the plugin's demo module.
(define (demo-file) (string-append (getenv "HOME") "/.config/tuna/lib/demo.sls"))

(call-with-output-file (demo-file)
  (lambda (p)
    (put-string p
      (call-with-input-file
        (format "~a/plugins/commands/tests/lib/commands-test/demo.sls" (path-parent (car (command-line))))
        get-string-all))))

(import (demo))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(define demo-names
  '(demo:hello demo:add demo:ordered demo:slow
    demo:which-task demo:pair-of demo:%hidden))


(test "a command is a procedure whose name is its module's prefix and its id"
  (check-equal? '(#t #t #f #f)
    (map commands:command? (list demo:hello demo:add car 'demo:hello)))
  (check-equal? '(demo:hello demo:ordered)
    (map commands:command-name (list demo:hello demo:ordered)))
  (check-raises (raised? 'commands:command-name "not a command") (commands:command-name car)))

(test "in a module, the doc string is the command's documentation"
  (check-equal? "Says hello to NAME." (definition-documentation demo:hello)))

(test "command-named finds a loaded command by the name a user types"
  (check (eq? demo:add (commands:command-named 'demo:add)))
  (check-equal? #f (commands:command-named 'demo:nothere))
  (check-raises (raised? 'commands:command-named "not a symbol") (commands:command-named "demo:add")))

(test "command-names lists the loaded commands in the order each was first defined; public-command-names leaves out % names"
  (check-equal? demo-names (commands:command-names))
  (check-equal? (remq 'demo:%hidden demo-names) (commands:public-command-names)))

(test "code calls a command with every argument, as any procedure, and no hook runs"
  (let* ([ran '()] [note (lambda (c) (set! ran (cons c ran)))])
    (hooks:add! commands:before-command note)
    (hooks:add! commands:after-command note)
    (check-equal? 3 (demo:add 1 2))
    (check-equal? "Hello, Groucho!" (demo:hello "Groucho"))
    (check-equal? '(4 5 6) (demo:pair-of 4 5 6))
    (hooks:remove! commands:before-command note)
    (hooks:remove! commands:after-command note)
    (check-equal? '() ran)))

(test "run with no arguments reads them with the interactive expressions, in order, in the running task; one may pause"
  (check-equal? "Hello, you!" (commands:run demo:hello))
  (check-equal? "Hello, Harpo!" (commands:run demo:hello "Harpo"))
  (check-equal? '(a b c) (commands:run demo:ordered))
  (check-equal? '(c b a) (demo:order))
  (check-equal? 'slept (commands:run demo:slow))
  (check (eq? (current-task) (commands:run demo:which-task))))

(test "one interactive expression may give several parameters, as its values"
  (check-equal? '(1 2 3) (commands:run demo:pair-of)))

(test "a parameter without an interactive expression must be given by the caller"
  (check-raises (raised? 'commands:run "a parameter has no interactive expression; pass the arguments")
    (commands:run demo:add))
  (check-equal? 5 (commands:run demo:add 2 3)))

(test "a malformed definition is a syntax error"
  (for-each
    (lambda (module message)
      (check-raises (syntax-error? message) (load-module! (list 'commands-test module))))
    '(no-string only-string string-name number-parameter no-expression two-expressions)
    '("expected (commands:define-command (id parameter ...) doc-string body ...+)"
      "expected (commands:define-command (id parameter ...) doc-string body ...+)"
      "expected (commands:define-command (id parameter ...) doc-string body ...+)"
      "not an identifier, [id expr] or [(id ...) expr]"
      "not an identifier, [id expr] or [(id ...) expr]"
      "not an identifier, [id expr] or [(id ...) expr]")))

(test "a command is a changeable definition: an override changes what its procedure and run call"
  (let ([hello demo:hello] [overridden (lambda args "overridden")])
    (override-set! demo:hello overridden)
    (check-equal? "overridden" (hello))
    (check-equal? "overridden" (commands:run demo:hello))
    (check (commands:command? hello))
    (override-remove! demo:hello)
    (check-equal? "Hello, Chico!" (hello "Chico"))))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick)
  (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 10000000 0)) (resume void))))))

(tables:define-table keymap)

(test "a reload keeps the procedure a command's name gives, so a key bound to it keeps working, and registers a command added to the file"
  (let ([hello demo:hello])
    (tables:set! keymap "C-h" demo:hello)
    (next-file-tick)
    (call-with-output-file (demo-file)
      (lambda (p) (put-string p "\n(commands:define-command (later) \"Added later.\" 'later)\n"))
      'append)
    (reload-modules! '((demo)))
    (check (eq? hello demo:hello))
    (check (commands:command? hello))
    (check-equal? "Hello, you!" (commands:run (tables:ref keymap "C-h" #f)))
    (check-equal? (append demo-names '(demo:later)) (commands:command-names))
    (check-equal? 'later (commands:run (commands:command-named 'demo:later)))))

(test "unloading a module unregisters its commands; loading it again registers the same procedures"
  (let ([hello demo:hello])
    (unload-owner! (module-owner '(demo)))
    (check-equal? #f (commands:command? hello))
    (check-equal? #f (commands:command-named 'demo:hello))
    (check-equal? '() (commands:command-names))
    (check-raises (raised? 'commands:run "not a command") (commands:run hello))
    (load-module! '(demo))
    (check (eq? hello (commands:command-named 'demo:hello)))
    (check (commands:command? hello))
    (check-equal? "Hello, you!" (commands:run hello))
    (check-equal? (append demo-names '(demo:later)) (commands:command-names))))

(test "a plugin marks a command's modes, and the commands that act on a region, in tables"
  (tables:set! commands:command-modes demo:hello '())
  (tables:set! commands:region-commands demo:hello #t)
  (check-equal? '() (tables:ref commands:command-modes demo:hello #f))
  (check-equal? #t (tables:ref commands:region-commands demo:hello #f))
  (tables:remove! commands:command-modes demo:hello)
  (tables:remove! commands:region-commands demo:hello))
