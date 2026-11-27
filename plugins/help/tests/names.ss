(import (tuna) (test) (test-runner) (test-user) (completion) (views) (buffers) (layout) (modes) (hooks) (options) (tables) (saved) (commands) (keys)
        (editing) (help) (help-test) (help-test harpo))

(define (raised-by who message)
  (lambda (c) (and (who-condition? c) (eq? who (condition-who c)) (string=? message (condition-message c)))))

(define (cancels-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (if (cancelled? c) 'cancelled c) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    reported))

;; A command a key's read resumes runs after the batch of that key, so
;; its screen is drawn one batch later.
(define (after-read) (test-user:settle))

(test-user:show! "|(help-test/harpo:squeeze 3) help-test/harpo:honk\n")

(define notes (views:buffer (layout:selected-view)))

(modes:set-major-mode help-test/harpo:mode notes)

(define notes-view (layout:selected-view))

(define (view) notes-view)

(define (describe name)
  (help:describe-name name (view))
  (test-user:settle)
  (help-test:lines))

(commands:define-command (bonk) "Bonks." (void))

(test "a command: its module, the keys that run it in the view, the modes it is marked for, its documentation, and each name a link"
  (check-equal? '("# help-test/harpo:honk" "<help-test/harpo:honk> is a command in (help-test harpo)." "It is on [C-c h]."
                  "It is for <help-test/harpo:mode>." "Honks once.")
                (describe 'help-test/harpo:honk))
  (check-equal? '("# help-test/harpo:quiet" "<help-test/harpo:quiet> is a command in (help-test harpo)."
                  "It is on no key; run it with [M-x] help-test/harpo:quiet." "It is for no mode." "Does nothing, on no key.")
                (describe 'help-test/harpo:quiet)))

(test "a command a test file or the configuration defines has no module"
  (help:describe-command bonk (view))
  (test-user:settle)
  (let ([name (symbol->string (commands:command-name bonk))])
    (check-equal? (list (string-append "# " name) (string-append "<" name "> is a command of the configuration or the REPL.")
                        (string-append "It is on no key; run it with [M-x] " name ".") "No documentation.")
                  (help-test:lines))))

(test "an option: its value in the view, its setting, its default, and each module's setting"
  (check-equal? '("# help-test/harpo:volume" "An option in (help-test harpo)." "Its value here is 3; its setting is 3 and its default 3."
                  "How loud a honk is.")
                (describe 'help-test/harpo:volume))
  (options:set! help-test/harpo:volume 7)
  (buffers:with-buffer notes (options:set-local! help-test/harpo:volume 9))
  (check-equal? '("# help-test/harpo:volume" "An option in (help-test harpo)." "Its value here is 9; its setting is 7 and its default 3."
                  "## Settings" "(test-file help names) sets it to 7." "How loud a honk is.")
                (describe 'help-test/harpo:volume)))

(test "a hook or a table: its documentation and how many entries it has; saved data: its value"
  (hooks:add! help-test/harpo:after-honk (lambda () 1))
  (tables:set! help-test/harpo:horns "bulb" "honk")
  (tables:set! help-test/harpo:horns "bell" "ding")
  (saved:set! help-test/harpo:honks 4)
  (check-equal? '("# help-test/harpo:after-honk" "A hook in (help-test harpo) with 1 entry." "Called after each honk.")
                (describe 'help-test/harpo:after-honk))
  (check-equal? '("# help-test/harpo:horns" "A table in (help-test harpo) with 2 entries." "Maps a horn's name to its sound.")
                (describe 'help-test/harpo:horns))
  (check-equal? '("# help-test/harpo:honks" "Saved data in (help-test harpo)." "Its value is 4.") (describe 'help-test/harpo:honks)))

(test "any other procedure: its documentation; any other value, as write prints it; syntax keeps no documentation"
  (check-equal? '("# help-test/harpo:squeeze" "A procedure in (help-test harpo)." "Squeezes the horn N times.")
                (describe 'help-test/harpo:squeeze))
  (check-equal? '("# help-test/harpo:mode" "A value in (help-test harpo)." "Its value is help-test/harpo:mode.")
                (describe 'help-test/harpo:mode))
  (check-equal? '("# help-test/harpo:with-horn" "Syntax in (help-test harpo), which keeps no documentation.")
                (describe 'help-test/harpo:with-horn)))

(test "Tuna's own libraries' names, and Chez's"
  (check-equal? '("# options:set!" "A procedure in (options)." "No documentation.") (describe 'options:set!))
  (check-equal? '("# plugins:eval-form" "A procedure in (plugins)." "No documentation.") (describe 'plugins:eval-form))
  (describe 'car)
  (check-equal? "car" (help-test:title)))

(test "the overrides and advice on a changeable definition follow, newest first, with who made each"
  (let ([lines (describe 'report)])
    (check-equal? '("# report" "A procedure in (tuna)." "No documentation." "## Changes") (list-head lines 4))
    (check (member "Advice by (echo-area)" lines)))
  (let ([advice (lambda (s n) (s n))])
    (override-set! help-test/harpo:squeeze (lambda (n) 0))
    (advice-add! help-test/harpo:squeeze advice)
    (check-equal? '("# help-test/harpo:squeeze" "A procedure in (help-test harpo)." "Squeezes the horn N times." "## Changes"
                    "Advice by (test-file help names)" "Override by (test-file help names)")
                  (describe 'help-test/harpo:squeeze))
    (advice-remove! help-test/harpo:squeeze advice)
    (override-remove! help-test/harpo:squeeze)))

(test "arguments are checked, and a name no loaded module exports is refused"
  (check-raises (raised-by 'help:describe-name "not an exported name") (help:describe-name 'nothere:x (view)))
  (check-raises (raised-by 'help:describe-name "not an exported name") (help:describe-name 'use-plugin (view)))
  (check-raises (raised-by 'help:describe-name "not an exported name") (help:describe-name (commands:command-name bonk) (view)))
  (check-raises (raised-by 'help:describe-name "not a symbol") (help:describe-name "help-test/harpo:honk" (view)))
  (check-raises (raised-by 'help:describe-name "not a view") (help:describe-name 'help-test/harpo:honk 'x))
  (check-raises (raised-by 'help:describe-command "not a command") (help:describe-command 'x (view)))
  (check-raises (raised-by 'help:describe-command "not a view") (help:describe-command help-test/harpo:honk 'x))
  (check-raises (raised-by 'help:apropos-command "not a command") (help:apropos-command 'x (view)))
  (check-raises (raised-by 'help:apropos-command "not a view") (help:apropos-command help-test/harpo:honk 'x)))

;; Completion matches on a job, so RET waits for the matches of what was
;; typed, as a user waits for the list to change.
(define (matched typed)
  (test-runner:wait-until
    (lambda ()
      (let ([v (layout:find-view (buffers:find " *Minibuf*"))])
        (and v
             (views:call-with-view v
               (lambda ()
                 (let ([s (completion:current-session)])
                   (and s (equal? typed (completion:session-input s)) (not (completion:session-busy? s)))))))))))

(define (read-and-describe keys typed)
  (layout:select! notes-view)
  (test-user:press! keys)
  (test-user:type! typed)
  (matched typed)
  (test-user:press! "RET")
  (after-read)
  (help-test:title))

(test "run by a key, C-h f, v and o read a name, the name at point first, and C-h x and a a command, the command at point first"
  (views:set-point! (view) 3)
  (check-equal? "help-test/harpo:squeeze" (read-and-describe "C-h f" ""))
  (views:set-point! (view) 26)
  (check-equal? "help-test/harpo:squeeze" (read-and-describe "C-h o" ""))
  (check-equal? "help-test/harpo:pitch" (read-and-describe "C-h v" "help-test/harpo:pitch"))
  (views:set-point! (view) 32)
  (check-equal? "help-test/harpo:honk" (read-and-describe "C-h x" ""))
  (check-equal? "help-test/harpo:quiet" (read-and-describe "C-h a" "help-test/harpo:quiet")))

(test "C-h f and C-h x also match inside a name, and C-h a matches the words of a command's name in any order"
  (check-equal? "help-test/harpo:squeeze" (read-and-describe "C-h f" "squeeze"))
  (check-equal? "help-test/harpo:honk" (read-and-describe "C-h x" "honk"))
  (check-equal? "help-test/harpo:quiet" (read-and-describe "C-h a" "quiet harpo")))

(test "names and commands each keep a history of their own"
  (check-equal? '("help-test/harpo:squeeze" "help-test/harpo:pitch") (help:name-history))
  (check-equal? '("help-test/harpo:quiet" "help-test/harpo:honk") (help:command-history)))

(test "C-h o offers a module's helpers, but no module's %scope, and C-h x only the commands M-x offers"
  (check-equal? "help:%read-name" (read-and-describe "C-h o" "help:%read-na"))
  (let ([before (help-test:title)])
    (test-user:press! "C-h o")
    (test-user:type! "help:%scop")
    (matched "help:%scop")
    (test-user:press! "RET")
    (after-read)
    (check-equal? before (help-test:title))
    (check-equal? '(cancelled) (cancels-during (lambda () (test-user:press! "C-g"))))
    (test-user:press! "C-h x")
    (test-user:type! "help:%fol")
    (matched "help:%fol")
    (test-user:press! "RET")
    (after-read)
    (check-equal? before (help-test:title))
    (check-equal? '(cancelled) (cancels-during (lambda () (test-user:press! "C-g"))))))
