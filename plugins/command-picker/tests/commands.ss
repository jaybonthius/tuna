(import (tuna) (test) (test-user) (options) (keys) (commands) (modes) (buffers) (document) (views) (layout) (web) (editing)
        (minibuffer) (completion) (completion-list) (command-picker) (buffer-picker)
        (minibuffer-test reading) (completion-test picking) (command-picker-test snake))

(define (name-of command) (symbol->string (commands:command-name command)))

(define (offered keys text)
  (test-user:press! keys)
  (test-user:type! text)
  (let ([found (completion-test/picking:choices)])
    (check-equal? '(cancelled) (completion-test/picking:quit!))
    found))

(define (bracket)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-message")])
    (and (pair? shown) (test-user:element-text (car shown)))))


(test "M-x runs the command chosen with the prefix argument, makes it the last command and adds its name to the history"
  (test-user:show! "|one two")
  (test-user:press! "C-u 3 M-x")
  (test-user:type! "editing:forward-char")
  (test-user:press! "RET")
  (check-equal? "one| two" (test-user:text))
  (check (eq? editing:forward-char (commands:last-command)))
  (check-equal? "editing:forward-char" (car (command-picker:command-history))))

(test "M-x refuses a name that is no command's with [No match], and the read stays"
  (test-user:press! "M-x")
  (test-user:type! "no-such")
  (test-user:press! "RET")
  (check-equal? " [No match]" (bracket))
  (check (minibuffer:current-prompt))
  (check-equal? '(cancelled) (completion-test/picking:quit!)))

(test "M-x leaves out private commands and those marked for no mode"
  (test-user:show! "|")
  (check-equal? '() (offered "M-x" "%answer"))
  (check-equal? '() (offered "M-x" "keys:ignore"))
  (check-equal? '() (offered "M-x" "keys:undefined")))

(test "M-x offers a command marked for a mode only where that mode is on, and M-X only the commands for the view's modes"
  (test-user:show! "|")
  (check-equal? '() (offered "M-x" (name-of command-picker-test/snake:run)))
  (check-equal? '() (offered "M-X" ""))
  (modes:set-major-mode command-picker-test/snake:mode (views:buffer (layout:selected-view)))
  (check-equal? (list (name-of command-picker-test/snake:run)) (offered "M-x" (name-of command-picker-test/snake:run)))
  (check-equal? (list (name-of command-picker-test/snake:run) (name-of command-picker-test/snake:anywhere)) (offered "M-X" "")))

(test "command-picker:command-predicate decides what M-x offers"
  (test-user:show! "|")
  (options:set! command-picker:command-predicate (lambda (command view) #t))
  (check-equal? '("keys:ignore") (offered "M-x" "keys:ignore"))
  (options:unset! command-picker:command-predicate))

(test "M-x offers a prompt's own commands only in a prompt, and completion's moves everywhere"
  (test-user:show! "|")
  (check-equal? '() (offered "M-x" "minibuffer:exit"))
  (check-equal? '() (offered "M-x" "completion:exit-input"))
  (check-equal? '("completion:next" "completion:next-group") (offered "M-x" "completion:next"))
  (check-equal? '("minibuffer:select-prompt") (offered "M-x" "minibuffer:select-prompt"))
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Word: " #f)))])
    (check-equal? '("minibuffer:exit") (offered "M-x" "minibuffer:exit"))
    (check-equal? '("completion:search-history") (offered "M-x" "completion:search-history"))
    (test-user:press! "C-g")
    (check-raises cancelled? (minibuffer-test/reading:result r))))

(test "M-x offers the answers of a y-or-n question only while point is in one"
  (test-user:show! "|")
  (check-equal? '() (offered "M-x" "minibuffer:answer-"))
  (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:ask-y-or-n "Save it? ")))])
    (check-equal? '("minibuffer:answer-no" "minibuffer:answer-yes") (offered "M-x" "minibuffer:answer-"))
    (test-user:press! "y")
    (check-equal? #t (minibuffer-test/reading:result r))))

(test "M-x reaches a session that completion:start runs over a field in any view"
  (test-user:show! "lis|")
  (let* ([tags (views:buffer (layout:selected-view))]
         [s (views:call-with-view (layout:selected-view)
              (lambda ()
                (completion:start (layout:selected-view) (list (completion:source (candidates (vector "lisp" "list" "listen"))))
                  (lambda () (values 1 (- (document:length (buffers:document tags)) 1)))
                  (lambda (session match) #f)
                  'none)))])
    (check-equal? #f (completion:selected s))
    (test-user:press! "M-x")
    (test-user:type! "completion:next")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (check-equal? "lisp" (completion:text s (completion:selected s)))
    (completion:end! s)))

(test "a command run from M-x reads its next key from the client that typed M-x, with the prefix argument M-x passed on"
  (test-user:show! "|")
  (let ([other (test-user:open-client)])
    (test-user:press! "C-u 2 M-x")
    (test-user:type! "editing:quoted-insert")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (check-equal? (list "M-x" #f) (list (keys:reading (test-user:client)) (keys:reading other)))
    (test-user:press! other "a")
    (test-user:press! "TAB")
    (check-equal? "a\t\t|" (test-user:text))
    (web:close-client! other)))

(test "with the default styles M-x matches inside a command's name, which starts with its plugin's name"
  (test-user:show! "|")
  (let ([found (offered "M-x" "forward-char")])
    (check (member "editing:forward-char" found))
    (check (member "editing:delete-forward-char" found))))

(test "an active region stays active through M-x, and the command chosen acts on it"
  (test-user:show! "|alpha beta")
  (test-user:press! "C-SPC M-f M-x")
  (test-user:type! "editing:upcase-region")
  (completion-test/picking:choices)
  (test-user:press! "RET")
  (check-equal? "ALPHA| beta" (test-user:text)))

(test "M-x runs its command inside a wrapper C-x 4 4 handed it, which a command run at the prompt does not see"
  (test-user:show! "|notes")
  (let* ([first (layout:selected-view)] [notes (views:buffer first)] [elsewhere (buffers:make "elsewhere" "x\n")])
    (test-user:press! "C-x 4 4 M-x")
    (test-user:type! "buffer-picker:switch-to-buffer")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (test-user:type! "elsewhere")
    (completion-test/picking:choices)
    (test-user:press! "RET")
    (check-equal? (list #f "elsewhere") (list (eq? first (layout:selected-view)) (buffers:name (views:buffer (layout:selected-view)))))
    (check (eq? notes (views:buffer first)))
    (test-user:press! "C-x 0")
    (buffers:kill! elsewhere)))
