(import (tuna) (test) (hooks) (tables) (commands) (commands-test demo)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(define demo-names
  '(commands-test/demo:hello commands-test/demo:add commands-test/demo:ordered commands-test/demo:slow
    commands-test/demo:which-task commands-test/demo:pair-of commands-test/demo:%hidden))

(define (demo-file) (string-append (getenv "HOME") "/.config/tuna/lib/commands-test/demo.sls"))

(test "a command is a procedure whose name is its module's prefix and its id"
  (check-equal? '(#t #t #f #f)
    (map commands:command? (list commands-test/demo:hello commands-test/demo:add car 'commands-test/demo:hello)))
  (check-equal? '(commands-test/demo:hello commands-test/demo:ordered)
    (map commands:command-name (list commands-test/demo:hello commands-test/demo:ordered)))
  (check-raises (raised? 'commands:command-name "not a command") (commands:command-name car)))

(test "in a module, the doc string is the command's documentation"
  (check-equal? "Says hello to NAME." (definition-documentation commands-test/demo:hello)))

(test "command-named finds a loaded command by the name a user types"
  (check (eq? commands-test/demo:add (commands:command-named 'commands-test/demo:add)))
  (check-equal? #f (commands:command-named 'commands-test/demo:nothere))
  (check-raises (raised? 'commands:command-named "not a symbol") (commands:command-named "commands-test/demo:add")))

(test "command-names lists the loaded commands in the order each was first defined; public-command-names leaves out % names"
  (check-equal? demo-names (commands:command-names))
  (check-equal? (remq 'commands-test/demo:%hidden demo-names) (commands:public-command-names)))

(test "code calls a command with every argument, as any procedure, and no hook runs"
  (let* ([ran '()] [note (lambda (c) (set! ran (cons c ran)))])
    (hooks:add! commands:before-command note)
    (hooks:add! commands:after-command note)
    (check-equal? 3 (commands-test/demo:add 1 2))
    (check-equal? "Hello, Groucho!" (commands-test/demo:hello "Groucho"))
    (check-equal? '(4 5 6) (commands-test/demo:pair-of 4 5 6))
    (hooks:remove! commands:before-command note)
    (hooks:remove! commands:after-command note)
    (check-equal? '() ran)))

(test "run with no arguments reads them with the interactive expressions, in order, in the running task; one may pause"
  (check-equal? "Hello, you!" (commands:run commands-test/demo:hello))
  (check-equal? "Hello, Harpo!" (commands:run commands-test/demo:hello "Harpo"))
  (check-equal? '(a b c) (commands:run commands-test/demo:ordered))
  (check-equal? '(c b a) (commands-test/demo:order))
  (check-equal? 'slept (commands:run commands-test/demo:slow))
  (check (eq? (current-task) (commands:run commands-test/demo:which-task))))

(test "one interactive expression may give several parameters, as its values"
  (check-equal? '(1 2 3) (commands:run commands-test/demo:pair-of)))

(test "a parameter without an interactive expression must be given by the caller"
  (check-raises (raised? 'commands:run "a parameter has no interactive expression; pass the arguments")
    (commands:run commands-test/demo:add))
  (check-equal? 5 (commands:run commands-test/demo:add 2 3)))

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
  (let ([hello commands-test/demo:hello] [overridden (lambda args "overridden")])
    (override-set! commands-test/demo:hello overridden)
    (check-equal? "overridden" (hello))
    (check-equal? "overridden" (commands:run commands-test/demo:hello))
    (check (commands:command? hello))
    (override-remove! commands-test/demo:hello)
    (check-equal? "Hello, Chico!" (hello "Chico"))))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick)
  (suspend (lambda (resume) (fork-task (lambda (restore) (chez:sleep (make-time 'time-duration 10000000 0)) (resume void))))))

(tables:define-table keymap)

(test "a reload keeps the procedure a command's name gives, so a key bound to it keeps working, and registers a command added to the file"
  (let ([hello commands-test/demo:hello])
    (tables:set! keymap "C-h" commands-test/demo:hello)
    (next-file-tick)
    (call-with-output-file (demo-file)
      (lambda (p) (put-string p "\n(commands:define-command (later) \"Added later.\" 'later)\n"))
      'append)
    (reload-modules! '((commands-test demo)))
    (check (eq? hello commands-test/demo:hello))
    (check (commands:command? hello))
    (check-equal? "Hello, you!" (commands:run (tables:ref keymap "C-h" #f)))
    (check-equal? (append demo-names '(commands-test/demo:later)) (commands:command-names))
    (check-equal? 'later (commands:run (commands:command-named 'commands-test/demo:later)))))

(test "unloading a module unregisters its commands; loading it again registers the same procedures"
  (let ([hello commands-test/demo:hello])
    (unload-owner! (module-owner '(commands-test demo)))
    (check-equal? #f (commands:command? hello))
    (check-equal? #f (commands:command-named 'commands-test/demo:hello))
    (check-equal? '() (commands:command-names))
    (check-raises (raised? 'commands:run "not a command") (commands:run hello))
    (load-module! '(commands-test demo))
    (check (eq? hello (commands:command-named 'commands-test/demo:hello)))
    (check (commands:command? hello))
    (check-equal? "Hello, you!" (commands:run hello))
    (check-equal? (append demo-names '(commands-test/demo:later)) (commands:command-names))))

(test "a plugin marks a command's modes, and the commands that act on a region, in tables"
  (tables:set! commands:command-modes commands-test/demo:hello '())
  (tables:set! commands:region-commands commands-test/demo:hello #t)
  (check-equal? '() (tables:ref commands:command-modes commands-test/demo:hello #f))
  (check-equal? #t (tables:ref commands:region-commands commands-test/demo:hello #f))
  (tables:remove! commands:command-modes commands-test/demo:hello)
  (tables:remove! commands:region-commands commands-test/demo:hello))
