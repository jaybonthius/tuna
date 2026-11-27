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

(test "press-button!, move-pointer! and release-button! hold the button between them; a release with no move is a click, one outside the view has no place"
  (test-user:show! "|one two")
  (test-user:settle)
  (take-seen!)
  (let ([v (layout:selected-view)])
    (test-user:press-button! v 1)
    (check-equal? '(("<down-mouse-1>" 1 1)) (take-seen!))
    (test-user:move-pointer! 3)
    (test-user:move-pointer! 5)
    (check-equal? '(("<mouse-movement>" 3 3) ("<mouse-movement>" 5 5)) (take-seen!))
    (test-user:release-button! 6)
    (check-equal? '(("<drag-mouse-1>" 1 6)) (take-seen!))
    (test-user:press-button! (test-user:client) v 2 "<down-mouse-1>")
    (test-user:release-button! (test-user:client) 2)
    (check-equal? '(("<down-mouse-1>" 2 2) ("<mouse-1>" 2 2)) (take-seen!))
    (test-user:press-button! v 1)
    (test-user:move-pointer! 4)
    (test-user:release-button! #f)
    (check-equal? '("<down-mouse-1>" "<mouse-movement>" "<drag-mouse-1>") (map car (take-seen!)))))

(test "a held button is pressed once and released once"
  (test-user:show! "|one")
  (test-user:settle)
  (take-seen!)
  (let ([v (layout:selected-view)])
    (check-raises (raised-by 'test-user:move-pointer!) (test-user:move-pointer! 1))
    (check-raises (raised-by 'test-user:release-button!) (test-user:release-button! 1))
    (check-raises (raised-by 'test-user:press-button!) (test-user:press-button! v 1 "<mouse-1>"))
    (test-user:press-button! v 1)
    (check-raises (raised-by 'test-user:press-button!) (test-user:press-button! v 2))
    (check-raises (raised-by 'test-user:click!) (test-user:click! v 2))
    (test-user:release-button! 1)
    (check-equal? '(("<down-mouse-1>" 1 1) ("<mouse-1>" 1 1)) (take-seen!))))

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

(test "click-element! on an element off any tokens and text, in a view that draws no line, sends no place, as the page does"
  (test-user:show! "|one two")
  (test-user:settle)
  (let* ([v (layout:selected-view)] [c (test-user:open-client)])
    (web:send-screen! c
      (haml (:div ([data-view (number->string (views:id v))] [data-version (number->string (buffers:version (views:buffer v)))]
                   [data-showing (number->string (views:shown-count v))])
              (:ul ([data-keymap (views:keymap-mark marked-keymap)])
                (:li.heading "Heading")
                (:div ([data-at "1"] [data-to "3"]) (:li "one")))))
      "Title")
    (take-seen!)
    (test-user:click-element! c (car (test-user:elements (test-user:screen c) "heading")) "<mouse-2>")
    (check-equal? '(("<mouse-2>" #f #f)) (take-seen!))
    (web:close-client! c)))

(tables:define-table cell-keymap "The keymap of a grid the tests mark.")

(commands:define-command (note-cell [event (keys:command-event)])
  "Notes the key of the event that ran it, the point of its start and the cell of its end."
  (set! seen (cons (list (keys:event-key event)
                         (views:posn-point (keys:event-start event))
                         (call-with-values (lambda () (views:posn-cell (keys:event-end event))) list))
                   seen)))

(for-each (lambda (key) (keys:bind! cell-keymap key note-cell))
  '("<mouse-2>" "<down-mouse-3>" "<mouse-movement>" "<drag-mouse-3>" "C-<wheel-up>" "<wheel-down>"))

;; A grid stands for the tokens 3 to 5 of the selected view's buffer and
;; takes the wheel. The layout draws its own screen at a batch's end, so
;; the grid's screen is sent again for each element read.
(define (grid-screen c)
  (let ([v (layout:selected-view)])
    (web:send-screen! c
      (haml (:div ([data-view (number->string (views:id v))] [data-version (number->string (buffers:version (views:buffer v)))]
                   [data-showing (number->string (views:shown-count v))])
              (:div ([data-at "3"] [data-to "5"] [data-keymap (views:keymap-mark cell-keymap)] [data-grid "shift"] [data-wheel "shift"])
                (:span.grid "two"))
              (:div ([data-at "1"] [data-to "3"])
                (:span.plain "one"))))
      "Title")
    (test-user:screen c)))

(define (grid c) (car (test-user:elements (grid-screen c) "grid")))

(define (plain c) (car (test-user:elements (grid-screen c) "plain")))

(test "click-cell! clicks a cell of an element, at the tokens it stands for, with the keymaps marked around it"
  (test-user:show! "|one two")
  (test-user:settle)
  (let ([c (test-user:open-client)])
    (take-seen!)
    (test-user:click-cell! c (grid c) 4 2 "<mouse-2>")
    (check-equal? '(("<mouse-2>" 3 (4 2))) (take-seen!))
    (web:close-client! c)))

(test "drag-cells! presses at one cell, moves to another and releases there"
  (test-user:show! "|one two")
  (test-user:settle)
  (let ([c (test-user:open-client)])
    (take-seen!)
    (test-user:drag-cells! c (grid c) 30 4 31 4 "<drag-mouse-3>")
        ;; A move carries no keymaps, as a page's does not, so it runs the
    ;; global binding.
    (check-equal? '(("<down-mouse-3>" 3 (30 4)) ("<mouse-movement>" 3 3) ("<drag-mouse-3>" 3 (31 4))) (take-seen!))
    (web:close-client! c)))

(test "wheel! turns the wheel over a cell of an element that takes it"
  (test-user:show! "|one two")
  (test-user:settle)
  (let ([c (test-user:open-client)])
    (take-seen!)
    (test-user:wheel! c (grid c) 0 0 "C-<wheel-up>")
    (test-user:wheel! c (grid c) 1 1 "<wheel-down>")
    (check-equal? '(("C-<wheel-up>" 3 (0 0)) ("<wheel-down>" 3 (1 1))) (take-seen!))
    (check-raises (raised-by 'test-user:wheel!) (test-user:wheel! c (grid c) 0 0 "<mouse-1>"))
    (check-raises (raised-by 'test-user:wheel!) (test-user:wheel! c (plain c) 0 0 "<wheel-up>"))
    (check-raises (raised-by 'test-user:click-cell!) (test-user:click-cell! c (grid c) -1 0 "<mouse-2>"))
    (check-raises (raised-by 'test-user:drag-cells!) (test-user:drag-cells! c (grid c) 0 0 1 0 "<mouse-2>"))
    (test-user:settle)
    (check-equal? '() (take-seen!))
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
