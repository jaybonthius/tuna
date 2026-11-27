(import (tuna) (test) (test-runner) (test-user) (modes) (prog) (buffers) (views) (layout) (keys) (commands) (tables) (editing)
        (completion-test sessions) (modes-test text) (modes-test code) (modes-test vim))

(define (view) (layout:selected-view))

(define (messages thunk) (map condition-message (test-runner:reports-during thunk)))

(define (keymaps)
  (let ([named (list (cons modes-test/vim:normal-keymap 'normal) (cons modes-test/vim:insert-keymap 'insert)
                     (cons modes-test/code:keymap 'code) (cons prog:keymap 'prog) (cons modes-test/text:keymap 'text)
                     (cons modes:fundamental-keymap 'fundamental) (cons layout:keymap 'layout))])
    (fold-right (lambda (k acc) (let ([n (assq k named)]) (if n (cons (cdr n) acc) acc)))
                '()
                (views:call-with-view (view) (lambda () (keys:active-keymaps (test-user:client)))))))

(define (show-code! text)
  (test-user:show! text)
  (modes:set-major-mode modes-test/code:mode (views:buffer (view))))

(test "a plugin's own keys:find-keymaps entry at depth 25 comes after the keymaps at the cursor and before every mode's"
  (show-code! "|f()\n")
  (check-equal? '(normal code prog layout) (keymaps)))

(test "a Vim-style normal state: typing inserts nothing, i enters insert state and ESC leaves it"
  (show-code! "|f()\n")
  (check-equal? '("x is undefined") (messages (lambda () (test-user:press! "x"))))
  (check-equal? "|f()\n" (test-user:text))
  (test-user:press! "i x y")
  (check-equal? "xy|f()\n" (test-user:text))
  (check-equal? '(insert code prog layout) (keymaps))
  (test-user:press! "ESC")
  (check-equal? '("z is undefined") (messages (lambda () (test-user:press! "z"))))
  (check-equal? "xy|f()\n" (test-user:text)))

(tables:define-table prog-normal)

(commands:define-command (forward) "Moves forward one character." (views:set-point! (view) (+ 1 (views:point (view)))))

(keys:bind! prog-normal "l" forward)

(test "a mode's own keys in normal state are found along its ancestry"
  (show-code! "|f()\n")
  (tables:set! modes-test/vim:normal-keymaps prog:mode prog-normal)
  (test-user:press! "l l")
  (check-equal? "f(|)\n" (test-user:text))
  (tables:remove! modes-test/vim:normal-keymaps prog:mode))

(test "the state a view starts in comes by major mode, and a mode switch forgets the states of the buffer's views"
  (tables:set! modes-test/vim:initial-states modes-test/text:mode modes-test/vim:insert-keymap)
  (test-user:show! "|")
  (modes:set-major-mode modes-test/text:mode (views:buffer (view)))
  (test-user:press! "h i")
  (check-equal? "hi|" (test-user:text))
  (show-code! "|f()\n")
  (test-user:press! "i")
  (check-equal? '(insert code prog layout) (keymaps))
  (modes:set-major-mode modes-test/code:mode (views:buffer (view)))
  (check-equal? '(normal code prog layout) (keymaps))
  (tables:remove! modes-test/vim:initial-states modes-test/text:mode))

(tables:define-table button-keymap)

(define pressed 0)

(commands:define-command (press-button) "Counts a press of the button." (set! pressed (+ pressed 1)))

(keys:bind! button-keymap "RET" press-button)

(buffers:define-kind button (content atom) (keymap button-keymap))

(test "a kind's keymap at the cursor still comes first in normal state"
  (let ([form (buffers:make "form" (list 'buffers:text '() "ab" (button '()) "cd"))])
    (views:set-buffer! (view) form)
    (views:set-point! (view) 3)
    (test-user:press! "RET")
    (check-equal? 1 pressed)))

(define (has-mark?)
  (let ([v (views:current)])
    (and v (views:cursor-mark (car (views:cursors v))) #t)))

(tables:define-table selection-keymap)

(define selected 0)

(commands:define-command (selection-command) "Runs only with a selection." (set! selected (+ selected 1)))

(keys:bind! selection-keymap "C-c x" selection-command)

(test "a when clause on a context key is a minor mode that reads the plugin's own state, with a keymap"
  (tables:set! modes:minor-modes has-mark? 0)
  (tables:set! modes:keymaps has-mark? selection-keymap)
  (tables:set! modes-test/vim:initial-states modes-test/code:mode modes-test/vim:insert-keymap)
  (show-code! "|f()\n")
  (check-equal? '("C-c x is undefined") (messages (lambda () (test-user:press! "C-c x"))))
  (test-user:press! "C-SPC")
  (test-user:press! "C-c x")
  (check-equal? 1 selected)
  (tables:remove! modes-test/vim:initial-states modes-test/code:mode)
  (tables:remove! modes:minor-modes has-mark?))
