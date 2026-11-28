(import (tuna) (test) (test-runner) (test-user) (views) (buffers) (layout) (modes) (options) (tables) (commands) (keys) (editing)
        (echo-area) (completion) (help) (help-test) (help-test harpo))

(define (report-messages thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (if (cancelled? c) 'cancelled (condition-message c)) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test-user:show! "|one\ntwo\n")

(define notes (views:buffer (layout:selected-view)))

(modes:set-major-mode help-test/harpo:mode notes)

(define (view) (layout:selected-view))

(test "C-h k reads a whole key sequence and shows in *Help* what it runs, the module that bound it and the command's description, with point at the start of the title"
  (test-user:press! "C-h k C-c h")
  (check-equal? '("# C-c h runs the command help-test/harpo:honk, bound by (help-test harpo)"
                  "<help-test/harpo:honk> is a command in (help-test harpo)." "It is on [C-c h]." "It is for <help-test/harpo:mode>."
                  "Honks once.")
                (help-test:lines))
  (check (eq? notes (views:buffer (view))))
  (check-equal? 2 (views:point (help-test:help-view))))

(test "a binding made by the test's own owner names that owner"
  (keys:bind! help-test/harpo:keymap "C-c h" help-test/harpo:quiet)
  (help:describe-key "C-c h" (view))
  (test-user:settle)
  (check-equal? "C-c h runs the command help-test/harpo:quiet, bound by (test-file help keys)" (help-test:title))
  (keys:bind! help-test/harpo:keymap "C-c h" help-test/harpo:honk))

(test "a sequence found through <printing-char>, shift or Meta names no binder"
  (keys:bind! keys:global "<printing-char>" editing:self-insert)
  (options:set! keys:quit-keys '("C-g"))
  (keys:unbind! keys:global "ESC")
  (keys:bind! keys:global "M-x" help-test/harpo:quiet)
  (check-equal? '("x runs the command editing:self-insert" "S-<right> runs the command editing:forward-char"
                  "ESC x runs the command help-test/harpo:quiet" "M-x runs the command help-test/harpo:quiet, bound by (test-file help keys)")
                (map (lambda (keys) (help:describe-key keys (view)) (test-user:settle) (help-test:title)) '("x" "S-<right>" "ESC x" "M-x")))
  (options:unset! keys:quit-keys)
  (keys:bind! keys:global "ESC" keys:keyboard-quit)
  (tables:remove! keys:global "M-x"))

(test "a prefix lists the bindings after it, one section per keymap, a sequence an earlier keymap decides left out of a later"
  (keys:bind! help-test/harpo:keymap "C-x h" help-test/harpo:honk)
  (keys:bind! keys:global "C-x h" help-test/harpo:quiet)
  (help:describe-key "C-x" (view))
  (test-user:settle)
  (let ([lines (help-test:lines)])
    (check-equal? '("# Key bindings starting with C-x" "## help-test/harpo:mode" "## keys:global") (help-test:outline))
    (check-equal? "[C-x h]  <help-test/harpo:honk>" (cadr (member "## help-test/harpo:mode" lines)))
    (check (not (member "[C-x h]  <help-test/harpo:quiet>" lines))))
  (tables:remove! keys:global "C-x h"))

(test "a click is looked up at its position, and C-h k reads past a press to the click, naming who bound it"
  (keys:bind! help-test/harpo:keymap "<mouse-1>" help-test/harpo:honk)
  (test-user:press! "C-h k")
  (test-user:click! (view) 2)
  (check-equal? "<mouse-1> at that spot runs the command help-test/harpo:honk, bound by (test-file help keys)" (help-test:title))
  (keys:unbind! help-test/harpo:keymap "<mouse-1>"))

(test "keys that run nothing are said to be undefined in the echo area, and *Help* stays as it was"
  (let ([before (help-test:title)])
    (test-user:press! "C-h k C-c z")
    (check-equal? '("C-c z is undefined" #t) (list (echo-area:current-message) (equal? before (help-test:title))))))

(test "a quit key cancels C-h k, describing nothing, and the echo area says Quit"
  (let ([before (help-test:title)])
    (for-each
      (lambda (keys)
        (check-equal? '(cancelled) (report-messages (lambda () (test-user:press! "C-h k") (test-user:press! keys))))
        (check-equal? before (help-test:title)))
      '("C-g" "C-x C-g" "ESC"))
    (check-equal? "Quit" (echo-area:current-message))))

(test "C-h k and C-h c ask with a prompt, which the reading keys give"
  (test-user:press! "C-h k")
  (check-equal? "Describe the following key or mouse click: " (keys:reading-prompt (test-user:client)))
  (test-user:press! "C-x")
  (check-equal? '("Describe the following key or mouse click: " "C-x") (list (keys:reading-prompt (test-user:client)) (keys:pending (test-user:client))))
  (report-messages (lambda () (test-user:press! "C-g")))
  (test-user:press! "C-h c")
  (check-equal? "Describe the following key or mouse click: " (keys:reading-prompt (test-user:client)))
  (test-user:press! "C-c h")
  (check-equal? "C-c h runs help-test/harpo:honk" (echo-area:current-message)))

(test "C-h c shows the first line in the echo area, without the binder"
  (help:describe-key-briefly "C-c z" (view))
  (check-equal? "C-c z is undefined" (echo-area:current-message))
  (help:describe-key-briefly "C-x" (view))
  (check-equal? "C-x is a prefix" (echo-area:current-message)))

(test "C-h w reads a command and shows the keys that run it"
  (test-user:press! "C-h w")
  (test-user:type! "help-test/harpo:honk\n")
  (check-equal? "help-test/harpo:honk is on C-c h, C-x h" (echo-area:current-message))
  (help:where-is help-test/harpo:quiet (view))
  (check-equal? "help-test/harpo:quiet is on no key" (echo-area:current-message)))

(test "a prefix then the help key describes the prefix, and any key bound to help:keymap is the help key"
  (test-user:press! "C-x C-h")
  (check-equal? "Key bindings starting with C-x" (help-test:title))
  (test-user:press! "C-h C-h")
  (check-equal? "Key bindings starting with C-h" (help-test:title))
  (keys:bind! keys:global "<f1>" help:keymap)
  (test-user:press! "C-c h")
  (test-user:press! "C-x <f1>")
  (check-equal? "Key bindings starting with C-x" (help-test:title))
  (check-equal? '("C-c z is undefined") (report-messages (lambda () (test-user:press! "C-c z")))))

(test "help:keymap is on C-h, and C-h e stays the echo area's"
  (check-equal? (list help:describe-key help:describe-name help:describe-name help:describe-name help:apropos-command echo-area:show-messages)
                (map (lambda (keys) (keys:lookup (test-user:client) keys)) '("C-h k" "C-h f" "C-h v" "C-h o" "C-h a" "C-h e")))
  (check (eq? help:keymap (keys:lookup (test-user:client) "C-h"))))

(test "help binds h in completion's action keymaps for commands and for names"
  (check-equal? (list help:describe-command help:describe-name)
                (list (keys:lookup-in (list completion:command-action-keymap) "h") (keys:lookup-in (list completion:name-action-keymap) "h"))))

(test "arguments are checked"
  (check-raises (test-runner:raised-with 'help:describe-key "neither a key sequence nor an event") (help:describe-key 'x (view)))
  (check-raises (test-runner:raised-with 'help:describe-key "not a view") (help:describe-key "C-x" 'x))
  (check-raises (test-runner:raised-with 'help:describe-key-briefly "neither a key sequence nor an event") (help:describe-key-briefly 'x (view)))
  (check-raises (test-runner:raised-with 'help:where-is "not a command") (help:where-is 'x (view))))
