(import (tuna) (test) (test-runner) (test-user) (modes) (prog) (buffers) (document) (views) (layout) (layout-split) (keys) (commands) (hooks)
        (options) (tables) (undo) (editing) (echo-area) (minibuffer) (completion) (command-picker) (help) (buffers-test)
        (completion-test sessions) (status-line) (status-line-test) (modes-test text) (modes-test fill) (modes-test code) (modes-test view) (modes-test probe))

(define (local option b) (buffers:with-buffer b (option)))

(define (session) (completion-test/sessions:session))

(define (rows)
  (let ([s (session)])
    (completion-test/sessions:wait-matches s)
    (map (lambda (m) (cons (completion:text s m) (apply string-append (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m)))))
         (completion-test/sessions:matches s))))

(define (offered) (map car (rows)))

(define (ours rows) (filter (lambda (row) (let ([t (car row)]) (and (> (string-length t) 11) (string=? "modes-test/" (substring t 0 11))))) rows))

(define (question)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-question")])
    (and (pair? shown) (test-user:element-text (car (reverse shown))))))

(define (raised-saying? who text)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (string=? text (apply format (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))))))

;; The prompt's own quit ends the command by a cancel, which is reported.
(define (quit!)
  (check-equal? '(#t) (map cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g"))))))

(define (ask-minor! . prefix)
  (for-each test-user:press! prefix)
  (test-user:press! "M-x")
  (test-user:type! "modes:toggle-minor-mode")
  (test-user:press! "RET"))

(define (toggle! name . prefix)
  (apply ask-minor! prefix)
  (test-user:type! name)
  (test-user:press! "RET")
  (check-equal? #f (completion-test/sessions:prompt)))

(modes:define-minor-mode for-text "Whether for-text is on." (majors modes-test/text:mode))

(define b (buffers:make "build" "import os\nprint(os.name)\n"))
(define other (buffers:make "other" "text\n"))
(define v (layout:selected-view))
(views:set-buffer! v b)
(define w (layout-split:split-view! v (layout-split:direction row)))
(views:set-buffer! w b)
(define x (layout-split:split-view! w (layout-split:direction row)))
(views:set-buffer! x other)
(layout:select! v)

(define (reset!)
  (modes:set-major-mode modes-test/code:mode b)
  (views:set-buffer! v b)
  (layout:select! v))

(test "the command asks Toggle minor mode: and offers the option modes for the buffer's major mode by name, in order, annotated with their state in the selected view"
  (reset!)
  (ask-minor!)
  (check-equal? "Toggle minor mode: " (question))
  (check-equal? '(("modes-test/fill:mode" . "off") ("modes-test/probe:counted-mode" . "off") ("modes-test/probe:talking-mode" . "off"))
                (ours (rows)))
  (check-equal? (list-sort string<? (offered)) (offered))
  (test-user:type! "off")
  (check-equal? '() (offered))
  (quit!)
  (views:set-option! v modes-test/fill:mode #t)
  (ask-minor!)
  (check-equal? '("modes-test/fill:mode" . "on") (assoc "modes-test/fill:mode" (rows)))
  (quit!)
  (views:remove-option! v modes-test/fill:mode))

(test "no state mode is offered, though each is a named minor mode"
  (reset!)
  (ask-minor!)
  (check-equal? 'modes-test/view:mode (modes:name modes-test/view:mode))
  (check-equal? #f (member "modes-test/view:mode" (offered)))
  (quit!))

(test "a minor mode for some major modes is offered only in their buffers"
  (reset!)
  (ask-minor!)
  (check-equal? #f (member "test-file/modes/toggle:for-text" (offered)))
  (quit!)
  (modes:set-major-mode modes-test/text:mode b)
  (ask-minor!)
  (check (member "test-file/modes/toggle:for-text" (offered)))
  (quit!))

(test "the mode is turned on with a local value in the buffer, which its other view shows; a view of another buffer and the global setting are unchanged"
  (reset!)
  (toggle! "modes-test/fill:mode")
  (check-equal? '(#t #t) (list (buffers:with-buffer b (options:local? modes-test/fill:mode)) (local modes-test/fill:mode b)))
  (check-equal? '(#t #f #f) (list (views:call-with-view w modes-test/fill:mode) (views:call-with-view x modes-test/fill:mode)
                                  (options:setting modes-test/fill:mode)))
  (check-equal? "modes-test/fill:mode enabled in current buffer" (echo-area:current-message)))

(test "a mode on everywhere is turned off in the buffer only"
  (reset!)
  (options:set! modes-test/fill:mode #t)
  (toggle! "modes-test/fill:mode")
  (check-equal? '(#f #t #t) (list (local modes-test/fill:mode b) (local modes-test/fill:mode other) (options:setting modes-test/fill:mode)))
  (check-equal? "modes-test/fill:mode disabled in current buffer" (echo-area:current-message))
  (options:unset! modes-test/fill:mode))

(test "a prefix argument of 1 or more turns the mode on whatever its state, one below 1 turns it off"
  (let ([with-prefix (lambda (state prefix)
                       (reset!)
                       (buffers:with-buffer b (options:set-local! modes-test/fill:mode state))
                       (apply toggle! "modes-test/fill:mode" prefix)
                       (local modes-test/fill:mode b))])
    (check-equal? '((#t #t) (#t #t) (#t #t) (#f #f) (#f #f))
                  (map (lambda (prefix) (list (with-prefix #t prefix) (with-prefix #f prefix)))
                       '(("C-u") ("M-5") ("M-1") ("M--") ("M-0"))))))

(test "a view's own value hides the buffer's: the buffer's value is set, and the message says the view keeps its own"
  (reset!)
  (views:set-option! v modes-test/fill:mode #f)
  (toggle! "modes-test/fill:mode")
  (check-equal? '(#t #t #f) (list (local modes-test/fill:mode b) (views:call-with-view w modes-test/fill:mode)
                                  (views:call-with-view v modes-test/fill:mode)))
  (check-equal? "modes-test/fill:mode enabled in current buffer; this view keeps its own value" (echo-area:current-message))
  (views:remove-option! v modes-test/fill:mode))

(test "the option's on-change runs once and options:changed is called once, for the value set"
  (reset!)
  (modes-test/probe:take-changes!)
  (let* ([reported '()] [entry (lambda (option value) (when (eq? option modes-test/probe:counted-mode) (set! reported (cons value reported))))])
    (hooks:add! options:changed entry)
    (toggle! "modes-test/probe:counted-mode")
    (check-equal? '((#t) (#t)) (list (modes-test/probe:take-changes!) reported))
    (hooks:remove! options:changed entry)))

(test "the mode's keymap is searched once it is on, and the status lines of both views of the buffer show its lighter"
  (reset!)
  (toggle! "modes-test/fill:mode")
  (check (memq modes-test/fill:keymap (views:call-with-view v (lambda () (keys:active-keymaps (test-user:client))))))
  (check-equal? '("Fill" "Fill" "")
                (map (lambda (view) (status-line-test:segment-text view 'status-line:minor-modes)) (list v w x))))

(test "nothing else changes: the major mode, the text, point and region, undo history, modified flag, selected view and views"
  (reset!)
  (views:set-point! v 10)
  (views:set-mark! v 4)
  (let* ([state (lambda ()
                  (list (modes:major-mode b) (document:text (buffers:document b)) (views:point v) (views:mark v) (undo:history b)
                        (buffers:modified? b) (layout:selected-view) (layout:views)))]
         [before (state)])
    (toggle! "modes-test/fill:mode")
    (check-equal? before (state))))

(test "an input that names no mode leaves the prompt waiting, saying No match; C-g quits, saying Quit, and nothing changes"
  (reset!)
  (ask-minor!)
  (test-user:type! "zz")
  (test-user:press! "RET")
  (check (completion-test/sessions:prompt))
  (check-equal? " [No match]" (completion-test/sessions:prompt-message))
  (quit!)
  (check-equal? (list "Quit" #f) (list (echo-area:current-message) (buffers:with-buffer b (options:local? modes-test/fill:mode)))))

(test "a switch of the major mode takes the toggled value away"
  (reset!)
  (toggle! "modes-test/fill:mode")
  (check-equal? #t (local modes-test/fill:mode b))
  (modes:switch-major-mode modes-test/text:mode b)
  (check-equal? #f (local modes-test/fill:mode b)))

(test "in a buffer whose mode is plugin-only a minor mode is turned on as anywhere"
  (reset!)
  (help:describe-mode v)
  (test-user:settle)
  (let ([help-buffer (buffers:find "*Help*")])
    (views:set-buffer! v help-buffer)
    (toggle! "modes-test/fill:mode")
    (check-equal? #t (local modes-test/fill:mode help-buffer))))

(test "from code, a state mode, an option that is no minor mode, a mode not for the buffer's major mode or a killed buffer raises and changes nothing"
  (reset!)
  (let ([gone (buffers:make "gone" "")])
    (buffers:kill! gone)
    (check-raises (buffers-test:raised? 'modes:toggle-minor-mode "not an option mode") (modes:toggle-minor-mode modes-test/view:mode b #t))
    (check-raises (buffers-test:raised? 'modes:toggle-minor-mode "not an option mode") (modes:toggle-minor-mode modes-test/fill:column b #t))
    (check-raises (raised-saying? 'modes:toggle-minor-mode "test-file/modes/toggle:for-text is not for modes-test/code:mode")
                  (modes:toggle-minor-mode for-text b #t))
    (check-raises (buffers-test:raised? 'modes:toggle-minor-mode "not a live buffer") (modes:toggle-minor-mode modes-test/fill:mode gone #t))
    (check-equal? '(79 #f #f) (list (local modes-test/fill:column b) (local modes-test/fill:mode b) (local for-text b)))))

(test "no key runs the command"
  (check-equal? '() (keys:where-is (test-user:client) modes:toggle-minor-mode)))

(commands:define-command (counted-on) "Turns modes-test/probe:counted-mode on in build." (modes:toggle-minor-mode modes-test/probe:counted-mode b #t))

(test "called from code inside another command it sets the value and the on-change runs, but it says nothing"
  (reset!)
  (modes-test/probe:take-changes!)
  (echo-area:message! "Before")
  (commands:run counted-on)
  (check-equal? (list #t '(#t) "Before") (list (local modes-test/probe:counted-mode b) (modes-test/probe:take-changes!) (echo-area:current-message))))

(test "a message the option's on-change writes is left in place of the command's"
  (reset!)
  (toggle! "modes-test/probe:talking-mode")
  (check-equal? (list #t "talking-mode is on") (list (local modes-test/probe:talking-mode b) (echo-area:current-message))))

(test "a minor mode goes with its plugin: no longer offered or named"
  (reset!)
  (let ([counted modes-test/probe:counted-mode])
    (unload-owner! (module-owner '(modes-test probe)))
    (ask-minor!)
    (check-equal? '(("modes-test/fill:mode" . "off")) (ours (rows)))
    (quit!)
    (check-equal? #f (modes:name counted))))
