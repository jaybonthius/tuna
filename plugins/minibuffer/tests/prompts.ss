(import (tuna) (test) (test-user) (hooks) (tables) (keys) (commands) (buffers) (document) (views) (layout) (layout-float) (web)
        (editing) (undo) (echo-area) (minibuffer) (reading))

(define (prompt-view) (minibuffer:prompt-view (reading:prompt)))

(define (selected-buffer-name) (buffers:name (views:buffer (layout:selected-view))))

(define (prompt-selected?) (eq? (layout:selected-view) (prompt-view)))

(define (prompt-elements) (test-user:elements (test-user:screen) "minibuffer-prompt"))

(define name #f)

(define %reports 0)

(define (click! v at)
  (for-each
    (lambda (action)
      (set! %reports (+ %reports 1))
      (web:post-input! (test-user:client)
        `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
          ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
          ("showing" . ,(views:shown-count v)) ("report" . ,%reports) ("at" . ,at) ("count" . 0))))
    '("down" "click"))
  (test-user:settle))

(test "with no prompt waiting the prompts' part draws nothing"
  (test-user:settle)
  (check-equal? '() (prompt-elements))
  (check-equal? "" (test-user:element-text (car (test-user:elements (test-user:screen) "minibuffer-prompts")))))

(test "the prompts' part sits at the bottom of the layout, locked"
  (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
    (let ([node (layout:view-node (prompt-view))])
      (check-equal? '(#t 100 content)
        (map (lambda (name) (document:node-attribute node name #f)) '(locked depth size))))
    (reading:quit! r)))

(test "nested prompts: only the innermost shows, marked with its depth; it is answered first, and the outer one comes back with its input and point"
  (let ([outer (reading:start! (lambda () (minibuffer:read "Outer: ")))])
    (test-user:type! "abc")
    (test-user:press! "C-b")
    (let ([inner (reading:start! (lambda () (minibuffer:read "Inner: ")))])
      (check-equal? 1 (length (prompt-elements)))
      (check-equal? '("Inner: ") (reading:questions))
      (check-equal? '("[2] ") (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-depth")))
      (test-user:type! "in")
      (test-user:press! "RET")
      (check-equal? "in" (reading:result inner)))
    (check-equal? 'waiting (reading:result outer))
    (check-equal? '("Outer: ") (reading:questions))
    (check-equal? "abc" (reading:input))
    (check-equal? (- (minibuffer:input-end (reading:prompt)) 1) (views:point (prompt-view)))
    (test-user:press! "RET")
    (check-equal? "abc" (reading:result outer))))

(test "answering an outer prompt while an inner one waits leaves the inner one shown and answerable"
  (let* ([outer-prompt #f]
         [outer (reading:start! (lambda () (minibuffer:call-with-setup (lambda (p) (set! outer-prompt p)) (lambda () (minibuffer:read "Outer: ")))))]
         [inner (reading:start! (lambda () (minibuffer:read "Inner: ")))])
    (minibuffer:exit! outer-prompt 'early)
    (test-user:settle)
    (check-equal? 'early (reading:result outer))
    (check-equal? '("Inner: ") (reading:questions))
    (check-equal? "" (reading:input))
    (test-user:type! "i")
    (test-user:press! "RET")
    (check-equal? "i" (reading:result inner))
    (check-equal? #f (reading:prompt))))

(test "a quit that lands between an answer and its task's resumption leaves the answer, and the prompt ends once"
  (let* ([ended 0] [count-end (lambda (p) (set! ended (+ ended 1)))])
    (hooks:add! minibuffer:prompt-ended count-end)
    (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
      (test-user:type! "x")
      (minibuffer:exit! (reading:prompt) (reading:input))
      (cancel-task (reading:task r))
      (test-user:settle)
      (check-equal? "x" (reading:result r)))
    (hooks:remove! minibuffer:prompt-ended count-end)
    (check-equal? 1 ended)))

(test "C-g and ESC quit the prompt, from its client or another; the view selected before is selected again"
  (test-user:show! "notes|")
  (let ([other (test-user:open-client)] [name (selected-buffer-name)])
    (for-each
      (lambda (client key)
        (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
          (test-user:press! client key)
          (check-raises cancelled? (reading:result r))
          (check-equal? #f (reading:prompt))
          (check-equal? "Quit" (echo-area:current-message))
          (check-equal? name (selected-buffer-name))))
      (list (test-user:client) (test-user:client) other)
      '("C-g" "ESC" "C-g"))
    (web:close-client! other)))

(test "C-g in another view while a prompt waits ends the prompt"
  (test-user:show! "notes|")
  (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
    (test-user:press! "C-x o")
    (check (not (prompt-selected?)))
    (test-user:press! "C-g")
    (check-raises cancelled? (reading:result r))
    (check-equal? #f (reading:prompt))))

(test "C-x o reaches the prompt after the level's views; deleting a view while the prompt waits selects the level's other view"
  (test-user:show! "notes|")
  (set! name (selected-buffer-name))
  (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
    (test-user:press! "C-x o")
    (check-equal? name (selected-buffer-name))
    (test-user:press! "C-x 2 C-x o")
    (check-equal? name (selected-buffer-name))
    (check (not (prompt-selected?)))
    (test-user:press! "C-x o")
    (check (prompt-selected?))
    (test-user:press! "C-x o")
    (check-equal? name (selected-buffer-name))
    (test-user:press! "C-x 0")
    (check-equal? name (selected-buffer-name))
    (check (not (prompt-selected?)))
    (views:call-with-view (layout:selected-view) (lambda () (commands:run minibuffer:select-prompt)))
    (check (prompt-selected?))
    (reading:quit! r)))

(test "a click puts point within the input, on the question at the input's start, and selects the prompt from another view"
  (test-user:show! "notes|")
  (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
    (test-user:type! "xyz")
    (let ([start (minibuffer:input-start (reading:prompt))] [v (prompt-view)])
      (click! v (+ start 1))
      (check-equal? (+ start 1) (views:point v))
      (click! v 3)
      (check-equal? start (views:point v))
      (test-user:press! "C-x o")
      (click! v (+ start 2))
      (check (prompt-selected?))
      (check-equal? (+ start 2) (views:point v)))
    (reading:quit! r)))

(tables:define-table extra "Keys a setup adds to a prompt.")

(commands:define-command (shout)
  "Answers the prompt in capitals."
  (let ([p (minibuffer:current-prompt)]) (minibuffer:exit! p (string-upcase (minibuffer:input p)))))

(keys:bind! extra "RET" shout)

(test "the prompt hooks follow each prompt; a keymap added in a setup wins in the input; content shows after the input"
  (let* ([seen '()]
         [note (lambda (what) (lambda (p) (set! seen (cons (list what (minibuffer:input p)) seen))))]
         [started (note 'started)] [changed (note 'changed)] [ended (note 'ended)])
    (hooks:add! minibuffer:prompt-started started)
    (hooks:add! minibuffer:input-changed changed)
    (hooks:add! minibuffer:prompt-ended ended)
    (let ([r (reading:start!
               (lambda ()
                 (minibuffer:call-with-setup
                   (lambda (p) (minibuffer:add-keymap! p extra) (minibuffer:set-content! p '("[list]")))
                   (lambda () (minibuffer:read "Name: ")))))])
      (check-equal? '("[list]") (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-content")))
      (test-user:type! "hi")
      (test-user:press! "RET")
      (check-equal? "HI" (reading:result r)))
    (hooks:remove! minibuffer:prompt-started started)
    (hooks:remove! minibuffer:input-changed changed)
    (hooks:remove! minibuffer:prompt-ended ended)
    (check-equal? '((started "") (changed "h") (changed "hi") (ended "hi")) (reverse seen))))

(test "content set on every key leaves the input's undo whole"
  (let ([show-input (lambda (p) (minibuffer:set-content! p (list (string-append "[" (minibuffer:input p) "]"))))]
        [content (lambda () (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-content")))])
    (hooks:add! minibuffer:input-changed show-input)
    (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
      (test-user:type! "ab cd")
      (check-equal? '("[ab cd]") (content))
      (test-user:press! "C-/")
      (check-equal? (list "" '("[]")) (list (reading:input) (content)))
      (check-equal? '("no further undo information") (reading:report-messages (lambda () (test-user:press! "C-/"))))
      (test-user:press! "C-?")
      (check-equal? (list "ab cd" '("[ab cd]")) (list (reading:input) (content)))
      (reading:quit! r))
    (hooks:remove! minibuffer:input-changed show-input)))

(test "with the palette rule a prompt shows in a palette, which C-x o leaves and reaches, and which goes when the prompt ends"
  (test-user:show! "notes|")
  (set! name (selected-buffer-name))
  (tables:set! layout:display-rules minibuffer:buffer? layout-float:display-palette)
  (let ([r (reading:start! (lambda () (minibuffer:read "Name: ")))])
    (check (layout:popup-node (prompt-view)))
    (check (prompt-selected?))
    (test-user:press! "C-x o")
    (check-equal? name (selected-buffer-name))
    (test-user:press! "C-x o")
    (check (prompt-selected?))
    (test-user:type! "x")
    (test-user:press! "RET")
    (check-equal? "x" (reading:result r))
    (check-equal? '() (test-user:elements (test-user:screen) "minibuffer-prompt"))
    (check-equal? name (selected-buffer-name)))
  (tables:remove! layout:display-rules minibuffer:buffer?))

(test "a prompt quit from its keys says Quit, after the outer prompt's input when one waits, which goes on waiting"
  (let* ([outcomes '()]
         [ask (lambda (question)
                (spawn-task
                  (lambda (restore)
                    (guard (c [(cancelled? c) (set! outcomes (cons (list question 'quit) outcomes))])
                      (minibuffer:read question)))))])
    (ask "Outer: ")
    (test-user:settle)
    (test-user:type! "out")
    (ask "Inner: ")
    (test-user:settle)
    (test-user:press! "C-g")
    (check-equal? '(("Inner: " quit)) outcomes)
    (check-equal? '("Outer: ") (reading:questions))
    (check-equal? " [Quit]" (reading:bracket))
    (test-user:press! "ESC")
    (check-equal? '(("Outer: " quit) ("Inner: " quit)) outcomes)
    (check-equal? "Quit" (echo-area:current-message))))
