(import (tuna) (test) (test-user) (web) (keys) (commands) (tables) (layout) (views) (buffers) (haml))

(define (raised-by who)
  (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))

(define seen '())

(define (take-seen!)
  (let ([s (reverse seen)]) (set! seen '()) s))

(commands:define-command (note-event [event (keys:command-event)])
  "Notes the key of the event that ran it and the points of its posns."
  (set! seen (cons (list (keys:event-key event)
                         (views:posn-point (keys:event-start event))
                         (views:posn-point (keys:event-end event)))
                   seen)))

(for-each (lambda (key) (keys:bind! keys:global key note-event))
  '("<down-mouse-1>" "<mouse-1>" "<drag-mouse-1>" "<mouse-movement>" "C-<double-down-mouse-3>" "C-<double-mouse-3>"))

(tables:define-table marked-keymap "The keymap of an element the tests mark.")

(keys:bind! marked-keymap "<mouse-2>" note-event)

(define (stale-reports thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (condition-message c) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(test "click! presses and releases a button on the text at a position, as the page sends them, and has run them when it returns"
  (test-user:show! "|one\ntwo")
  (test-user:settle)
  (take-seen!)
  (test-user:click! (layout:selected-view) 5)
  (check-equal? '(("<down-mouse-1>" 5 5) ("<mouse-1>" 5 5)) (take-seen!))
  (test-user:click! (test-user:client) (layout:selected-view) 2 "C-<double-mouse-3>")
  (check-equal? '(("C-<double-down-mouse-3>" 2 2) ("C-<double-mouse-3>" 2 2)) (take-seen!)))

(test "click! clicks the view as the client's last screen drew it, so a click before a new buffer is drawn is stale"
  (test-user:show! "|one")
  (test-user:settle)
  (test-user:show! "|two")
  (take-seen!)
  (check-equal? '("Stale click: what was clicked is gone") (stale-reports (lambda () (test-user:click! (layout:selected-view) 1))))
  (check-equal? '() (take-seen!)))

(test "drag! presses at one position, moves to another and releases there"
  (test-user:show! "|one two")
  (test-user:settle)
  (take-seen!)
  (test-user:drag! (layout:selected-view) 1 5)
  (check-equal? '(("<down-mouse-1>" 1 1) ("<mouse-movement>" 5 5) ("<drag-mouse-1>" 1 5)) (take-seen!)))

(test "click-element! clicks an element of the last screen: its view's, at the tokens it stands for, with the keymaps marked around it"
  (test-user:show! "|one two")
  (test-user:settle)
  (let* ([v (layout:selected-view)] [c (test-user:open-client)])
    (web:send-screen! c
      (haml (:div ([data-view (number->string (views:id v))] [data-version (number->string (buffers:version (views:buffer v)))]
                   [data-showing (number->string (views:shown-count v))])
              (:div ([data-at "3"] [data-to "5"] [data-keymap (views:keymap-mark marked-keymap)])
                (:span.target "two"))))
      "Title")
    (take-seen!)
    (test-user:click-element! c (car (test-user:elements (test-user:screen c) "target")) "<mouse-2>")
    (check-equal? '(("<mouse-2>" 3 3)) (take-seen!))
    (web:close-client! c)))

(test "a click is refused before anything is posted: a key that is no click or drag, a view or a line not drawn, an element of no screen or standing for no tokens"
  (test-user:show! "|one")
  (test-user:settle)
  (take-seen!)
  (let ([v (layout:selected-view)])
    (check-raises (raised-by 'test-user:click!) (test-user:click! v 1 "<down-mouse-1>"))
    (check-raises (raised-by 'test-user:click!) (test-user:click! v 1 "H-<mouse-1>"))
    (check-raises (raised-by 'test-user:click!) (test-user:click! v 1 "C-a"))
    (check-raises (raised-by 'test-user:drag!) (test-user:drag! v 1 2 "<mouse-1>"))
    (check-raises (raised-by 'test-user:click!) (test-user:click! v 99 "<mouse-1>"))
    (check-raises (raised-by 'test-user:click!) (test-user:click! (views:make (buffers:make (buffers:free-name "elsewhere") "x")) 0))
    (check-raises (raised-by 'test-user:click-element!) (test-user:click-element! '(span "x")))
    (check-raises (raised-by 'test-user:click-element!)
                  (test-user:click-element! (car (test-user:elements (test-user:screen) "view-lines")))))
  (test-user:settle)
  (check-equal? '() (take-seen!)))
