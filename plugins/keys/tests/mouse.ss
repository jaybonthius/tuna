(import (tuna) (test) (test-user) (views) (layout) (hooks) (tables) (commands) (keys) (keys-test))

(define (mouse-item action button clicks modifiers)
  (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" clicks)
        (cons "modifiers" (list->vector modifiers))))

(test "a mouse item names its mouse key from its action, button, the press's click count and the modifiers, with Option as alt"
  (check-equal? "S-<double-down-mouse-1>" (keys:item-key (mouse-item "down" 1 2 '("shift"))))
  (check-equal? '("C-M-s-<mouse-1>" "C-M-s-<triple-drag-mouse-1>" "C-M-s-<down-mouse-1>" "C-M-s-<triple-mouse-1>" "C-M-s-<mouse-movement>")
                (map (lambda (action clicks) (keys:item-key (mouse-item action 1 clicks '("control" "alt" "super"))))
                     '("click" "drag" "down" "click" "move")
                     '(1 3 1 6 2))))

(test "the browser's count of a run's presses is counted in threes from at least 1"
  (check-equal? '("<down-mouse-1>" "<down-mouse-1>" "<double-down-mouse-1>" "<triple-down-mouse-1>" "<down-mouse-1>"
                  "<double-down-mouse-1>" "<triple-down-mouse-1>" "<down-mouse-1>")
                (map (lambda (clicks) (keys:item-key (mouse-item "down" 1 clicks '()))) '(0 1 2 3 4 5 6 7)))
  (check-equal? "<down-mouse-3>" (keys:item-key (mouse-item "down" 3 4 '()))))

(test "every button is named by its number"
  (check-equal? '("<mouse-2>" "<mouse-3>" "<mouse-8>" "<mouse-9>")
                (map (lambda (button) (keys:item-key (mouse-item "click" button 1 '()))) '(2 3 8 9))))

(test "a wheel item names a wheel key by its direction, with modifiers and no count"
  (check-equal? '("<wheel-up>" "C-<wheel-down>" "M-<wheel-left>" "S-<wheel-right>")
                (map (lambda (direction modifiers)
                       (keys:item-key (list (cons "type" "mouse") (cons "action" "wheel") (cons "direction" direction)
                                            (cons "modifiers" modifiers))))
                     '("up" "down" "left" "right")
                     '(#() #("control") #("alt") #("shift"))))
  (check-raises (keys-test:raised-by 'keys:item-key "a wheel item without a direction")
    (keys:item-key '(("type" . "mouse") ("action" . "wheel") ("direction" . "in") ("modifiers" . #())))))

(test "a key item with a name names that key, which must be one key and no mouse key"
  (check-equal? '("C-f" "RET" "<f1>" "x")
                (map (lambda (name) (keys:item-key (list (cons "type" "key") (cons "name" name)))) '("C-f" "RET" "<f1>" "x")))
  (for-each
    (lambda (name)
      (check-raises (keys-test:raised-by 'keys:item-key "not a key's name") (keys:item-key (list (cons "type" "key") (cons "name" name)))))
    '("C-x C-f" "<mouse-1>" "<wheel-up>" 7)))

(test "a mouse item without an action, a button, a click count or a known modifier is refused"
  (check-raises (keys-test:raised-by 'keys:item-key "a mouse item without an action") (keys:item-key (mouse-item "hover" 1 1 '())))
  (check-raises (keys-test:raised-by 'keys:item-key "a mouse item without a button")
    (keys:item-key '(("type" . "mouse") ("action" . "down") ("clicks" . 1) ("modifiers" . #()))))
  (check-raises (keys-test:raised-by 'keys:item-key "a mouse item without a click count") (keys:item-key (mouse-item "down" 1 -1 '())))
  (check-raises (keys-test:raised-by 'keys:item-key "not a modifier name") (keys:item-key (mouse-item "down" 1 1 '("left-option")))))

(test "an event is a mouse key and a posn, or for a drag two; any value but #f is a posn"
  (let ([press '("S-<double-down-mouse-1>" #(3 1205))] [drag '("<drag-mouse-1>" #(3 10) #(3 20))])
    (check-equal? '(#t #t #f #f #f #t #f #t #f)
                  (map keys:event? (list press drag "<mouse-1>" '("<mouse-1>" #(3 1) #(3 2)) '("C-x" #(3 1)) '("<mouse-1>" 4)
                                         '("<mouse-1>" #f) '("C-<wheel-up>" here) '("<double-wheel-up>" here))))
    (check-equal? '("S-<double-down-mouse-1>" #(3 1205) #(3 1205) 2)
                  (list (keys:event-key press) (keys:event-start press) (keys:event-end press) (keys:event-clicks press)))
    (check-equal? '(#(3 10) #(3 20) 1 3 1)
                  (list (keys:event-start drag) (keys:event-end drag) (keys:event-clicks drag)
                        (keys:event-clicks '("<triple-mouse-1>" #(1 1))) (keys:event-clicks '("<mouse-movement>" #(1 1)))))
    (for-each
      (lambda (read who) (check-raises (keys-test:raised-by who "not an event") (read "<mouse-1>")))
      (list keys:event-key keys:event-start keys:event-end keys:event-clicks keys:event-basic-type keys:event-modifiers)
      '(keys:event-key keys:event-start keys:event-end keys:event-clicks keys:event-basic-type keys:event-modifiers))))

(test "an event's basic type is its button, wheel or move; its modifiers are those held, then the action"
  (check-equal? '((mouse-3 (control meta down)) (mouse-2 (drag)) (mouse-9 (shift super click)) (wheel-left (control)) (mouse-movement ())
                  (mouse-1 (control down)))
                (map (lambda (e) (list (keys:event-basic-type e) (keys:event-modifiers e)))
                     '(("C-M-<double-down-mouse-3>" a) ("<drag-mouse-2>" a b) ("S-s-<triple-mouse-9>" a) ("C-<wheel-left>" a)
                       ("<mouse-movement>" a) ("C-<double-down-mouse-1>" posn)))))

(define seen '())

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(define (summary event)
  (if (keys:event? event) (cons (keys:event-key event) (map views:posn-point (cdr event))) event))

(commands:define-command (record-event [event (keys:command-event)])
  "Records the event that ran it."
  (set! seen (cons (list (summary event) (keys:command-keys) (keys:shift-translated?)) seen)))

(tables:define-table clicked-keymap "Keys for clicks in the test's buffer.")

(define (with-clicked-keymap thunk)
  (let ([entry (lambda (client posn) (if posn (list clicked-keymap) '()))])
    (hooks:add! keys:find-keymaps entry -50)
    (test-user:show! "|0123456789")
    (test-user:settle)
    (thunk)
    (hooks:remove! keys:find-keymaps entry)))

(keys:bind! clicked-keymap "<mouse-8>" record-event)
(keys:bind! clicked-keymap "<down-mouse-8>" record-event)

(test "a command reads the event that ran it, a posn of views' making; outside a command there is none"
  (with-clicked-keymap
    (lambda ()
      (test-user:click! (layout:selected-view) 7 "<mouse-8>")
      (check-equal? '((("<down-mouse-8>" 7) "<down-mouse-8>" #f) (("<mouse-8>" 7) "<mouse-8>" #f)) (take-seen!))))
  (check-equal? #f (keys:command-event)))

(test "a mouse key that nothing binds tries fewer clicks, then a drag as the click at its start, then the key without shift"
  (with-clicked-keymap
    (lambda ()
      (test-user:click! (layout:selected-view) 7 "<triple-mouse-8>")
      (test-user:drag! (layout:selected-view) 8 9 "S-<double-drag-mouse-8>")
      (check-equal? '((("<triple-down-mouse-8>" 7) "<triple-down-mouse-8>" #f) (("<triple-mouse-8>" 7) "<triple-mouse-8>" #f)
                      (("S-<double-down-mouse-8>" 8) "S-<double-down-mouse-8>" #t) (("S-<double-mouse-8>" 8) "S-<double-drag-mouse-8>" #t))
                    (take-seen!))
      (keys:bind! clicked-keymap "<double-mouse-8>" keys:ignore)
      (test-user:click! (layout:selected-view) 7 "<triple-mouse-8>")
      (check-equal? '((("<triple-down-mouse-8>" 7) "<triple-down-mouse-8>" #f)) (take-seen!))
      (tables:remove! clicked-keymap "<double-mouse-8>"))))

(test "a press or a move that nothing binds is dropped without a warning and keeps the pending keys; an unbound click is undefined"
  (with-clicked-keymap
    (lambda ()
      (test-user:press! "C-x")
      (check-equal? '("C-x <drag-mouse-9> is undefined")
                    (keys-test:report-messages (lambda () (test-user:drag! (layout:selected-view) 1 2 "<drag-mouse-9>"))))
      (check-equal? #f (keys:pending (test-user:client)))
      (test-user:press! "C-x")
      (check-equal? '("C-x <mouse-9> is undefined")
                    (keys-test:report-messages (lambda () (test-user:click! (layout:selected-view) 2 "<mouse-9>"))))
      (check-equal? #f (keys:pending (test-user:client))))))

(test "keys:ignore keeps a mouse key from the keymaps searched later, and a mouse key pressed as a key is looked up as a typed one"
  (tables:define-table near-keymap "near")
  (keys:bind! near-keymap "<mouse-8>" keys:ignore)
  (keys:bind! keys:global "<mouse-8>" record-event)
  (with-clicked-keymap
    (lambda ()
      (let ([entry (lambda (client posn) (if posn (list near-keymap) '()))])
        (hooks:add! keys:find-keymaps entry -60)
        (test-user:click! (layout:selected-view) 7 "<mouse-8>")
        (check-equal? '((("<down-mouse-8>" 7) "<down-mouse-8>" #f)) (take-seen!))
        (check-equal? record-event (keys:lookup (test-user:client) "<mouse-8>"))
        (keys:press! (test-user:client) "<mouse-8>")
        (check-equal? '(("<mouse-8>" "<mouse-8>" #f)) (take-seen!))
        (hooks:remove! keys:find-keymaps entry))))
  (tables:remove! keys:global "<mouse-8>"))

(test "a sequence is looked up in the keymaps of its first key, so a mouse key after a typed prefix finds the typed keymaps"
  (keys:bind! keys:global "C-c <mouse-8>" record-event)
  (with-clicked-keymap
    (lambda ()
      (test-user:press! "C-c")
      (test-user:click! (layout:selected-view) 5 "<mouse-8>")
      (check-equal? '((("<mouse-8>" 5) "C-c <mouse-8>" #f)) (take-seen!)))))

(test "entries of find-keymaps get the event's start posn, and #f for a typed key"
  (let* ([posns '()]
         [entry (lambda (client posn) (when (eq? client (test-user:client)) (set! posns (cons posn posns))) '())])
    (test-user:show! "|0123456789")
    (test-user:settle)
    (hooks:add! keys:find-keymaps entry -50)
    (check-equal? '("<drag-mouse-9> is undefined")
                  (keys-test:report-messages (lambda () (test-user:drag! (layout:selected-view) 2 4 "<drag-mouse-9>"))))
    (test-user:press! "C-x")
    (check-equal? '("C-x C-g is undefined") (keys-test:report-messages (lambda () (test-user:press! "C-g"))))
    (hooks:remove! keys:find-keymaps entry)
    (check-equal? '(2 4 2 #f #f) (map (lambda (p) (and p (views:posn-point p))) (reverse posns)))))
