(import (tuna) (test) (test-user) (test-runner) (modes) (prog) (python) (buffers) (document) (views) (layout) (keys) (commands)
        (hooks) (options) (tables) (ask) (files) (undo) (editing) (echo-area) (minibuffer) (completion) (command-picker) (help)
        (buffers-test) (completion-test sessions) (status-line) (status-line-test) (modes-test text) (modes-test fill) (modes-test code) (modes-test view))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(define (local option b) (buffers:with-buffer b (option)))

(define (view) (layout:selected-view))

(define (session) (completion-test/sessions:session))

(define (offered)
  (let ([s (session)])
    (completion-test/sessions:wait-matches s)
    (completion-test/sessions:texts s)))

(define (annotated)
  (let ([s (session)])
    (completion-test/sessions:wait-matches s)
    (fold-right
      (lambda (m acc)
        (let ([note (apply string-append (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m)))])
          (if (string=? note "") acc (cons (cons (completion:text s m) note) acc))))
      '()
      (completion-test/sessions:matches s))))

(define (reports-of thunk)
  (map (lambda (c)
         (cond
           [(cancelled? c) 'cancelled]
           [(and (format-condition? c) (irritants-condition? c)) (apply format (condition-message c) (condition-irritants c))]
           [else (condition-message c)]))
       (test-runner:reports-during thunk)))

;; The prompt's own quit ends the command by a cancel, which is reported.
(define (quit!) (check-equal? '(cancelled) (reports-of (lambda () (test-user:press! "C-g")))))

(define (ask-major! . prefix)
  (for-each test-user:press! prefix)
  (test-user:press! "M-x")
  (test-user:type! "modes:switch-major-mode")
  (test-user:press! "RET"))

(define (question)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-question")])
    (and (pair? shown) (test-user:element-text (car (reverse shown))))))

(define (raised-saying? who text)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (string=? text (apply format (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))))))

(define (answer! text)
  (test-user:type! text)
  (test-user:press! "RET"))

(define (switch! name)
  (ask-major!)
  (answer! name)
  (check-equal? #f (completion-test/sessions:prompt)))

(write-file! "build.py" "import os\nprint(os.name)\n")

(define b (files:visit (home-file "build.py")))

(define v (view))

(views:set-buffer! v b)

(define (reset!)
  (modes:set-major-mode modes:fundamental b)
  (views:set-buffer! v b)
  (layout:select! v))

(test "the command asks Major mode: and offers the major modes that are not plugin-only, by name, in alphabetical order; nothing changes before an answer"
  (reset!)
  (views:set-point! v 10)
  (views:set-mark! v 4)
  (ask-major!)
  (check-equal? "Major mode: " (question))
  (check-equal? '("chez-scheme:mode" "modes-test/code:mode" "modes-test/text:mode" "modes:fundamental" "modes:special" "prog:mode"
                    "python:mode")
                (offered))
  (check-equal? (list modes:fundamental 10 4) (list (modes:major-mode b) (views:point v) (views:mark v)))
  (quit!))

(test "the current mode is annotated current, outside what the input matches, and the first candidate is selected"
  (reset!)
  (modes:set-major-mode python:mode b)
  (ask-major!)
  (check-equal? '(("python:mode" . "current")) (annotated))
  (check-equal? "chez-scheme:mode" (completion-test/sessions:selected-text (session)))
  (test-user:type! "current")
  (check-equal? '() (offered))
  (quit!))

(test "typing the name in full, or a part and RET on the selected candidate, answers it"
  (reset!)
  (switch! "python:mode")
  (check-equal? python:mode (modes:major-mode b))
  (reset!)
  (ask-major!)
  (test-user:type! "pyth")
  (check-equal? '("python:mode") (offered))
  (test-user:press! "RET")
  (check-equal? python:mode (modes:major-mode b)))

(test "an input that names no mode leaves the prompt waiting, saying No match; C-g quits, saying Quit, and nothing changes"
  (reset!)
  (buffers:with-buffer b (options:set-local! modes-test/fill:column 60))
  (ask-major!)
  (answer! "zz")
  (check (completion-test/sessions:prompt))
  (check-equal? " [No match]" (completion-test/sessions:prompt-message))
  (quit!)
  (check-equal? (list "Quit" modes:fundamental 60) (list (echo-area:current-message) (modes:major-mode b) (local modes-test/fill:column b))))

(test "with no reader for choices, the command reports that none is loaded and changes nothing"
  (reset!)
  (check-equal? '("no reader is loaded")
                (reports-of (lambda ()
                              (options:with ([ask:choice-reader (options:default ask:choice-reader)])
                                (buffers:with-buffer b (commands:run modes:switch-major-mode))))))
  (check-equal? modes:fundamental (modes:major-mode b)))

(hooks:define-hook probe "A hook given local entries.")

(test "the answer sets the buffer's mode: local values, local hook entries and local minor modes go; global, state and view values stay"
  (reset!)
  (let ([probed (lambda () 'probed)] [other (views:make b)])
    (options:set! modes-test/fill:mode #t)
    (buffers:with-buffer b
      (options:set-local! modes-test/fill:column 60)
      (options:set-local! modes-test/fill:mode #f)
      (hooks:add-local! probe probed))
    (views:set-option! v editing:electric-indent #f)
    (modes-test/view:set-viewing! b #t)
    (switch! "python:mode")
    (check-equal? (list python:mode 70 #t '() #t)
                  (list (modes:major-mode b) (local modes-test/fill:column b) (local modes-test/fill:mode b)
                        (buffers:with-buffer b (hooks:entries probe)) (local modes-test/view:mode b)))
    (check-equal? '(#f #t) (list (views:call-with-view v editing:electric-indent) (views:call-with-view other editing:electric-indent)))
    (check-equal? '(#t #t) (list (modes:on? python:mode v) (modes:on? python:mode other)))
    (check-equal? "Python" (status-line-test:segment-text v 'status-line:major-mode))
    (views:remove-option! v editing:electric-indent)
    (modes-test/view:set-viewing! b #f)
    (options:unset! modes-test/fill:mode)
    (views:drop! other)))

(test "the text, point, region, undo history, modified flag and file stay, nothing is edited, and no view changes"
  (reset!)
  (views:set-point! v 10)
  (views:set-mark! v 4)
  (let* ([edits 0]
         [count-edit (lambda (buffer edit) (when (eq? buffer b) (set! edits (+ edits 1))))]
         [state (lambda ()
                  (list (document:text (buffers:document b)) (views:point v) (views:mark v) (undo:history b) (buffers:modified? b)
                        (files:path b) (view) (layout:views) (views:buffer v)))]
         [before (state)])
    (hooks:add! buffers:after-edit count-edit)
    (switch! "python:mode")
    (check-equal? before (state))
    (check-equal? 0 edits)
    (hooks:remove! buffers:after-edit count-edit)))

(buffers:define-layer locked (read-only))

(tables:define-table keyed-keymap)

(buffers:define-kind keyed (keymap keyed-keymap))

(buffers:define-kind sealed (consent (lambda (node edit) #f)))

(buffers:define-kind page (content nodes))

(test "read-only spans and kinds stay and still refuse edits, and a kind's keymap still comes before the mode's"
  (let ([k (buffers:make "kinds" (page '() (keyed '() "(define [x] 1)\n") (sealed '() "(c)\n")))])
    (modes:set-major-mode modes-test/code:mode k)
    (buffers:add-span! (buffers:layer k locked) 2 4 #t)
    (views:set-buffer! v k)
    (views:set-point! v 3)
    (switch! "python:mode")
    (check-equal? python:mode (modes:major-mode k))
    (check-equal? '((2 4)) (map (lambda (s) (list (car s) (cadr s))) (buffers:spans (buffers:layer k locked) 0 20)))
    (check-raises (buffers-test:raised? 'buffers:replace! "the text of kinds is read-only") (buffers:replace! k 3 3 "x"))
    (check-raises (buffers-test:raised? 'buffers:replace! "the node refuses the edit") (buffers:replace! k 20 20 "x"))
    (let ([keymaps (views:call-with-view v (lambda () (keys:active-keymaps (test-user:client))))])
      (check-equal? (list keyed-keymap python:keymap prog:keymap)
                    (filter (lambda (k) (memq k (list keyed-keymap python:keymap prog:keymap modes:fundamental-keymap))) keymaps)))))

(test "the command writes nothing in the echo area once the prompt closes"
  (reset!)
  (echo-area:message! "Before")
  (switch! "python:mode")
  (check-equal? #f (echo-area:current-message)))

(test "the command asks, then runs the mode hooks outermost first with the buffer current, then major-mode-changed"
  (reset!)
  (buffers:with-buffer b (options:set-local! modes-test/fill:column 50))
  (let* ([recorded '()]
         [record! (lambda what (set! recorded (cons what recorded)))]
         [prog-entry (lambda () (record! 'prog-hook (eq? (buffers:current) b) (modes-test/fill:column)))]
         [code-entry (lambda () (record! 'code-hook (eq? (buffers:current) b) (modes-test/fill:column)))]
         [changed-entry (lambda (buffer) (when (eq? buffer b) (record! 'major-mode-changed (eq? (buffers:current) b) (modes-test/fill:column))))]
         [prompt-entry (lambda (p) (record! 'prompt))]
         [entries (list (cons prog:mode-hook prog-entry) (cons modes-test/code:mode-hook code-entry)
                        (cons modes:major-mode-changed changed-entry) (cons minibuffer:prompt-started prompt-entry))])
    (for-each (lambda (e) (hooks:add! (car e) (cdr e))) entries)
    (switch! "modes-test/code:mode")
    (check-equal? '((prompt) (prompt) (prog-hook #t 70) (code-hook #t 79) (major-mode-changed #t 79))
                  (reverse recorded))
    (set! recorded '())
    (buffers:with-buffer b (options:set-local! modes-test/fill:column 50))
    (ask-major!)
    (check-equal? '(("modes-test/code:mode" . "current")) (annotated))
    (answer! "modes-test/code:mode")
    (check-equal? '((prog-hook #t 70) (code-hook #t 79) (major-mode-changed #t 79))
                  (filter (lambda (r) (memq (car r) '(prog-hook code-hook major-mode-changed))) (reverse recorded)))
    (for-each (lambda (e) (hooks:remove! (car e) (cdr e))) entries)))

(test "in a buffer whose hooks wait, the switch runs them and major-mode-changed, not delayed-mode-changed"
  (reset!)
  (let* ([calls '()]
         [hooked (lambda () (set! calls (cons 'hook calls)))]
         [changed (lambda (buffer) (set! calls (cons 'changed calls)))]
         [delayed (lambda (buffer) (set! calls (cons 'delayed calls)))])
    (modes:set-major-mode-delaying-hooks modes-test/code:mode b)
    (hooks:add! modes-test/code:mode-hook hooked)
    (hooks:add! modes:major-mode-changed changed)
    (hooks:add! modes:delayed-mode-changed delayed)
    (switch! "modes-test/code:mode")
    (check-equal? '(hook changed) (reverse calls))
    (check-equal? #f (modes:hooks-delayed? b))
    (hooks:remove! modes-test/code:mode-hook hooked)
    (hooks:remove! modes:major-mode-changed changed)
    (hooks:remove! modes:delayed-mode-changed delayed)))

(define help-buffer
  (begin
    (help:describe-mode v)
    (test-user:settle)
    (buffers:find "*Help*")))

(test "in a buffer whose mode is plugin-only no prompt opens: the command reports why and changes nothing"
  (views:set-buffer! v help-buffer)
  (check-equal? '("help:mode is set only by its plugin")
                (reports-of (lambda () (test-user:press! "M-x") (test-user:type! "modes:switch-major-mode") (test-user:press! "RET"))))
  (check-equal? (list #f help:mode) (list (completion-test/sessions:prompt) (modes:major-mode help-buffer)))
  (views:set-buffer! v b))

(test "from a waiting prompt the command refuses, naming minibuffer:mode, and the prompt still waits with its input"
  (reset!)
  (let ([outer (completion-test/sessions:start! (lambda () (minibuffer:read "Name: ")))])
    (test-user:type! "abc")
    (check-equal? '("minibuffer:mode is set only by its plugin")
                  (reports-of (lambda () (test-user:press! "M-x") (test-user:type! "modes:switch-major-mode") (test-user:press! "RET"))))
    (check-equal? (list "abc" #t) (list (completion-test/sessions:input) (completion-test/sessions:waiting? outer)))
    (test-user:press! "C-g")
    (check-equal? #f (completion-test/sessions:waiting? outer))))

(test "from code, a plugin-only mode, a buffer in one, a mode not defined or a killed buffer raises and changes nothing"
  (reset!)
  (let ([gone (buffers:make "gone" "")])
    (buffers:kill! gone)
    (check-raises (raised-saying? 'modes:switch-major-mode "help:mode is set only by its plugin") (modes:switch-major-mode help:mode b))
    (check-raises (raised-saying? 'modes:switch-major-mode "help:mode is set only by its plugin")
                  (modes:switch-major-mode python:mode help-buffer))
    (check-raises (buffers-test:raised? 'modes:switch-major-mode "not a major mode") (modes:switch-major-mode 'nothing:mode b))
    (check-raises (buffers-test:raised? 'modes:switch-major-mode "not a live buffer") (modes:switch-major-mode python:mode gone))
    (check-equal? (list modes:fundamental help:mode) (list (modes:major-mode b) (modes:major-mode help-buffer)))))

(test "a major mode is offered while its plugin is loaded"
  (reset!)
  (let ([text-offered? (lambda () (ask-major!) (let ([o (offered)]) (quit!) (and (member "modes-test/text:mode" o) #t)))])
    (check-equal? #t (text-offered?))
    (unload-owner! (module-owner '(modes-test text)))
    (check-equal? #f (text-offered?))
    (load-module! '(modes-test text))
    (check-equal? #t (text-offered?))))

(test "a prefix argument changes nothing: the prompt and the switch are as without"
  (for-each
    (lambda (prefix)
      (reset!)
      (ask-major! prefix)
      (check-equal? "Major mode: " (question))
      (check-equal? '("chez-scheme:mode" "modes-test/code:mode" "modes-test/text:mode" "modes:fundamental" "modes:special" "prog:mode"
                    "python:mode")
                    (offered))
      (answer! "python:mode")
      (check-equal? python:mode (modes:major-mode b)))
    '("C-u" "M-5")))

(test "no key runs the command"
  (check-equal? '() (keys:where-is (test-user:client) modes:switch-major-mode)))

(test "a mode chosen by hand, and the local values its hooks set, last through a revert, a save and a reload of modes"
  (reset!)
  (switch! "modes-test/code:mode")
  (write-file! "build.py" "import sys\nprint(sys.path)\n")
  (test-user:press! "C-x x g")
  (check-equal? (list "import sys\nprint(sys.path)\n" modes-test/code:mode 79)
                (list (document:text (buffers:document b)) (modes:major-mode b) (local modes-test/fill:column b)))
  (buffers:replace! b 1 1 "# x\n")
  (test-user:press! "C-x C-s")
  (test-runner:wait-until (lambda () (not (buffers:modified? b))))
  (check-equal? modes-test/code:mode (modes:major-mode b))
  (reload-modules! '((modes)))
  (check-equal? (list modes-test/code:mode 79) (list (modes:major-mode b) (local modes-test/fill:column b))))

(test "a later entry in modes:plugin-only wins over the plugin's mark: the mode is offered and its buffers are switched"
  (tables:set! modes:plugin-only help:mode #f)
  (reset!)
  (ask-major!)
  (check (member "help:mode" (offered)))
  (quit!)
  (views:set-buffer! v help-buffer)
  (switch! "prog:mode")
  (check-equal? prog:mode (modes:major-mode help-buffer))
  (tables:remove! modes:plugin-only help:mode))
