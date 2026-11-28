(import (tuna) (test) (test-user) (test-runner) (options) (hooks) (timers) (keys) (tables) (commands) (modes) (buffers) (document) (views) (layout) (minibuffer)
        (completion) (completion-popup) (editing) (web) (completion-test sessions) (minibuffer-test reading))

(define (session) (completion-test/sessions:session))

(define (texts) (completion-test/sessions:texts (session)))

(define (selected) (completion-test/sessions:selected-text (session)))

(define (word-region words)
  (lambda ()
    (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)] [s (editing:forward-word-position b p -1)])
      (and (< s p) (= (editing:forward-word-position b s 1) p)
           (completion:region s p (list (completion:source (candidates (list->vector words)))))))))

(define greek (word-region '("alpha" "almond" "alpine" "alphabet" "apple")))

(define (with-region entry thunk)
  (hooks:add! completion:find-region entry)
  (thunk)
  (when (session) (test-user:press! "C-g"))
  (hooks:remove! completion:find-region entry))

(define (popup-roots) (test-user:elements (test-user:screen) "completion-popup"))

;; Views nest, so the popup's view is the last view element around its root.
(define (popup-view)
  (let ([around (filter (lambda (e) (pair? (test-user:elements e "completion-popup")))
                        (test-user:elements-with (test-user:screen) "data-view"))])
    (and (pair? around)
         (views:find (string->number (test-user:element-attribute (car (last-pair around)) "data-view"))))))

(define (popup-size)
  (let ([node (layout:popup-node (popup-view))])
    (list (document:node-attribute node 'width #f) (document:node-attribute node 'height #f))))

(define (popup-rows)
  (map test-user:element-text (test-user:elements (car (popup-roots)) "completion-text")))

;; The claims below are that nothing starts, so the test waits past the
;; delay rather than for an event.
(define (past-delay) (timers:sleep 0.2) (test-user:settle))

(test "a session at point shows its matches in a popup of the layout, as wide as its content and as tall as its rows, whose view draws no cursor; its end closes it"
  (with-region greek
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (check-equal? '("alpha" "alpine" "alphabet") (popup-rows))
      (check-equal? '(content (lines 3)) (popup-size))
      (check-equal? #f (buffers:with-buffer (views:buffer (popup-view)) (views:cursor-visible)))
      (test-user:type! "i")
      (check-equal? '(("alpine") (content (lines 1))) (list (popup-rows) (popup-size)))
      (test-user:press! "C-g")
      (check-equal? '() (popup-roots)))))

(test "the popup is at most completion-popup:lines lines tall, and C-v and M-v move the selection a page of them"
  (options:set! completion-popup:lines 2)
  (with-region greek
    (lambda ()
      (test-user:show! "al|")
      (test-user:press! "C-M-i")
      (check-equal? '("alpha" "almond" "alpine" "alphabet") (texts))
      (check-equal? '(content (lines 2)) (popup-size))
      (test-user:press! "C-v")
      (check-equal? "almond" (selected))
      (test-user:press! "C-v")
      (check-equal? "alphabet" (selected))
      (test-user:press! "M-v")
      (check-equal? "almond" (selected))))
  (options:unset! completion-popup:lines))

(test "the popup's root carries completion-popup:min-width and completion-popup:max-width for the page"
  (options:set! completion-popup:min-width 20 completion-popup:max-width 30)
  (with-region greek
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (check-equal? "--completion-popup-min-width:20ch;--completion-popup-max-width:30ch"
                    (test-user:element-attribute (car (popup-roots)) "style"))))
  (options:unset! completion-popup:min-width completion-popup:max-width))

(test "a popup grows taller as a stream adds rows while fewer than fit are shown"
  (let* ([feed #f]
         [region (lambda ()
                   (let ([p (views:point (views:current))])
                     (completion:region 1 p (list (completion:source (stream (lambda (emit) (set! feed emit) (lambda (prefix) (void)))))))))])
    (with-region region
      (lambda ()
        (test-user:show! "x|")
        (test-user:press! "C-M-i")
        (feed (vector "x1"))
        (test-runner:wait-until (lambda () (= 1 (length (texts)))))
        (test-user:settle)
        (check-equal? '(content (lines 1)) (popup-size))
        (feed (vector "x2" "x3"))
        (test-runner:wait-until (lambda () (= 3 (length (texts)))))
        (test-user:settle)
        (check-equal? '(content (lines 3)) (popup-size))
        (feed 'done)))))

(test "M-n and M-p move the selection in the popup, and M-w keeps its meaning in the buffer"
  (with-region greek
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (test-user:press! "M-n M-n")
      (check-equal? "alpine" (selected))
      (test-user:press! "M-p")
      (check-equal? "alpha" (selected))
      (check (eq? editing:kill-ring-save (keys:lookup (test-user:client) "M-w"))))))

(test "a click on a popup row chooses it"
  (with-region greek
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (let ([row (find (lambda (row) (string=? "alpine" (test-user:element-text row)))
                       (test-user:elements (car (popup-roots)) "ui-list-row"))])
        (test-user:click-element! row))
      (check-equal? "alpine|" (test-user:text))
      (check-equal? #f (session)))))

(test "a session at point in a prompt is drawn by a popup, and no list is made for the prompt"
  (let ([prompt-words (lambda ()
                        (let ([p (minibuffer:current-prompt)])
                          (and p (eq? (views:current) (minibuffer:prompt-view p))
                               (completion:region (minibuffer:input-start p) (views:point (views:current))
                                 (list (completion:source (candidates (vector "alpha" "almond"))))))))])
    (with-region prompt-words
      (lambda ()
        (let ([r (minibuffer-test/reading:start! (lambda () (minibuffer:read "Eval: " #f)))])
          (test-user:type! "al")
          (test-user:press! "C-M-i")
          (check-equal? '("alpha" "almond") (popup-rows))
          (check-equal? '() (test-user:elements (test-user:screen) "completion-list"))
          (test-user:press! "C-g")
          (test-user:press! "C-g")
          (check-raises cancelled? (minibuffer-test/reading:result r)))))))

(test "by default completion at point never starts by itself"
  (with-region greek
    (lambda ()
      (test-user:show! "|")
      (test-user:type! "alp")
      (past-delay)
      (check-equal? #f (session)))))

(define (auto! delay thunk)
  (with-region greek
    (lambda ()
      (test-user:show! "|")
      (buffers:with-buffer (views:buffer (layout:selected-view))
        (options:set-local! completion-popup:auto-delay delay))
      (thunk))))

(define (wait-for-session) (test-runner:wait-until session) (test-user:settle))

(test "with completion-popup:auto-delay, typing completion-popup:auto-prefix characters opens the popup after the delay, inserting and selecting nothing"
  (auto! 0.05
    (lambda ()
      (test-user:type! "alp")
      (wait-for-session)
      (check-equal? '("alpha" "alpine" "alphabet") (popup-rows))
      (check-equal? #f (completion:selected (session)))
      (check-equal? "alp|" (test-user:text)))))

(test "fewer characters than completion-popup:auto-prefix start nothing, and the option sets how many"
  (auto! 0.05
    (lambda ()
      (test-user:type! "al")
      (past-delay)
      (check-equal? #f (session))
      (options:set! completion-popup:auto-prefix 2)
      (test-user:press! "DEL")
      (test-user:type! "l")
      (wait-for-session)
      (check-equal? '("alpha" "almond" "alpine" "alphabet") (texts))))
  (options:unset! completion-popup:auto-prefix))

(test "only the commands of completion-popup:auto-commands start it, DEL and <delete> among them by default"
  (auto! 0.05
    (lambda ()
      (test-user:type! "alph")
      (wait-for-session)
      (test-user:press! "C-g")
      (test-user:press! "C-b <delete>")
      (wait-for-session)
      (check-equal? "alp|" (test-user:text))
      (check-equal? '("alpha" "alpine" "alphabet") (texts))
      (test-user:press! "C-g")
      (options:set! completion-popup:auto-commands (list editing:delete-backward-char))
      (test-user:type! "h")
      (past-delay)
      (check-equal? #f (session))
      (test-user:press! "DEL")
      (wait-for-session)
      (check-equal? '("alpha" "alpine" "alphabet") (texts))))
  (options:unset! completion-popup:auto-commands))

(define (reports-during thunk)
  (map condition-message (test-runner:reports-during thunk)))

(test "a popup's moving keys are the starting client's: at another client showing it, M-n is undefined and the selection stays"
  (with-region greek
    (lambda ()
      (test-user:show! "alp|")
      (test-user:press! "C-M-i")
      (let ([other (test-user:open-client)])
        (test-user:settle)
        (check-equal? 1 (length (test-user:elements (test-user:screen other) "completion-popup")))
        (check-equal? '("M-n is undefined") (reports-during (lambda () (test-user:press! other "M-n"))))
        (check-equal? #f (completion:selected (session)))
        (test-user:press! "M-n")
        (check-equal? "alpha" (selected))
        (web:close-client! other)))))

(commands:define-command (typed-through [n (commands:prefix-number)] [char (keys:typed-char)])
  "Types CHAR as editing:self-insert does, as a minor mode's own typing command may."
  (editing:self-insert n char))

(tables:define-table remapping-keymap "Remaps typing to typed-through.")

(keys:remap! remapping-keymap editing:self-insert typed-through)

(modes:define-minor-mode remapping-mode
  "Whether typing runs typed-through."
  (keymap remapping-keymap))

(test "a command a minor mode remaps one of completion-popup:auto-commands to starts it too"
  (auto! 0.05
    (lambda ()
      (buffers:with-buffer (views:buffer (layout:selected-view)) (options:set-local! remapping-mode #t))
      (test-user:type! "alp")
      (wait-for-session)
      (check-equal? '("alpha" "alpine" "alphabet") (popup-rows)))))
