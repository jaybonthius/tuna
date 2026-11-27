(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (document) (keys) (commands) (web) (options) (ask)
        (layout-test parts) (layout-test boxes))

(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define mail (buffers:make "mail" "Dear Harpo,\n"))

(define (fresh b) (views:make b))

(define (id-of v) (views:id v))

(define (keymap-names client)
  (map (lambda (k)
         (cond
           [(eq? k layout-test/boxes:box-keys) 'box]
           [(eq? k layout:keymap) 'layout]
           [(eq? k keys:global) 'global]
           [else 'other]))
       (keys:active-keymaps client)))

(define (start-boxes!)
  (let ([a (fresh notes)] [b (fresh mail)] [c (fresh notes)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (layout-test/parts:atom a)
        (layout-test/boxes:box '() (layout-test/parts:atom b) (layout-test/parts:atom c))))
    (layout:select! a)
    (values a b c)))

(test "every client shows the same selected view, and selecting gives each container on its path that focused child"
  (let-values ([(a b c) (start-boxes!)])
    (let ([other (test-user:open-client)])
      (layout:select! b)
      (test-user:settle)
      (for-each
        (lambda (client)
          (check-equal? (list (cons (id-of a) #f) (cons (id-of b) #t) (cons (id-of c) #f))
                        (layout-test/parts:drawn-views client)))
        (list (test-user:client) other))
      (layout:select! c)
      (let ([box (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node c)))])
        (check-equal? "notes" (layout:part-title box))
        (layout:select! a)
        (layout:select! b)
        (check-equal? "mail" (layout:part-title box)))
      (check-equal? (map id-of (list a b c)) (map id-of (layout:views)))
      (web:close-client! other))))

(test "select! takes a view in the layout"
  (let ([gone (fresh notes)])
    (views:drop! gone)
    (check-raises (layout-test/parts:raised-with 'views:id "a dropped view") (layout:select! gone))
    (check-raises (layout-test/parts:raised-with 'layout:select! "not a view") (layout:select! 'nothing))
    (check-raises (layout-test/parts:raised-with 'layout:select! "not a view in the layout") (layout:select! (fresh notes)))))

(test "a move toward a direction asks each container up the path, passes through a kind with no neighbour clause, and goes into a sibling's focused child"
  (let-values ([(a b c) (start-boxes!)])
    (layout:select! b)
    (layout:select! c)
    (check-equal? (id-of c) (id-of (layout:neighbour a (layout:direction right))))
    (check-equal? '(#f #f) (list (layout:neighbour a (layout:direction left)) (layout:neighbour a (layout:direction up))))
    (check-equal? (id-of a) (id-of (layout:neighbour b (layout:direction left))))
    (check-equal? #f (layout:neighbour c (layout:direction right)))
    (check-raises (layout-test/parts:raised-with 'layout:neighbour "not a direction") (layout:neighbour a 'north))
    (check-equal? '(left up) (enum-set->list (layout:directions up left)))))

(test "the focus path gives the selected view's keymaps, then each enclosing container's kind's, then the layout's"
  (let-values ([(a b c) (start-boxes!)])
    (let ([client (test-user:client)])
      (check-equal? '(layout global) (keymap-names client))
      (layout:select! c)
      (check-equal? '(box layout global) (keymap-names client))
      (check (eq? layout-test/boxes:box-command (keys:lookup client "C-c b")))
      (check (eq? (car (layout:container-keymaps client #f)) layout-test/boxes:box-keys)))))

(define last-where #f)

(commands:define-command (where)
  "Keeps the current view and buffer."
  (set! last-where (list (views:id (views:current)) (buffers:name (buffers:current)))))

(keys:bind! keys:global "C-c w" where)

(test "keys from a client run in the selected view, and each client has its own keys in progress"
  (let-values ([(a b c) (start-boxes!)])
    (let ([c1 (test-user:client)] [c2 (test-user:open-client)])
      (test-user:press! c1 "C-x")
      (check-equal? "C-x" (keys:pending c1))
      (check-equal? #f (keys:pending c2))
      (test-user:press! c1 "o")
      (check (eq? b (layout:selected-view)))
      (test-user:press! c2 "C-x o")
      (check (eq? c (layout:selected-view)))
      (layout:select! a)
      (test-user:press! c2 "C-c w")
      (check-equal? (list (id-of a) "notes") last-where)
      (check-equal? (list (id-of a) "notes")
                    (views:call-with-view (layout:selected-view)
                      (lambda () (list (views:id (views:current)) (buffers:name (buffers:current))))))
      (web:close-client! c2))))

(test "C-x o goes round the views of the level in the layout's order"
  (let-values ([(a b c) (start-boxes!)])
    (commands:run layout:other-view)
    (check (eq? b (layout:selected-view)))
    (commands:run layout:other-view)
    (commands:run layout:other-view)
    (check (eq? a (layout:selected-view)))))

(test "a click on the layout's drawing selects the view its part leads to; the Super moves select neighbours"
  (let-values ([(a b c) (start-boxes!)])
    (commands:run layout:mouse-select-view
      (list "<mouse-1>" (views:%make-posn layout:screen-view (document:node-start (layout:view-node c)))))
    (check (eq? c (layout:selected-view)))
    (check-equal? '((layout:mouse-select-view "not an event"))
                  (layout-test/parts:refusals-during (lambda () (commands:run layout:mouse-select-view 999))))
    (commands:run layout:select-left)
    (check (eq? a (layout:selected-view)))
    (commands:run layout:select-right)
    (check (eq? c (layout:selected-view)))
    (commands:run layout:select-up)
    (check (eq? c (layout:selected-view)))))

(test "zoom draws the selected view in place of its level's part and keeps the parts outside the level; selecting a view it hides ends it"
  (let-values ([(a b c) (start-boxes!)])
    (layout:select! c)
    (let ([echo (layout-test/parts:place-echo! (buffers:make "*Echo*" ""))])
      (check (eq? echo (layout-test/parts:place-echo! (views:buffer echo))))
      (check (layout:locked? (layout:view-node echo)))
      (check (not (layout:locked? (layout:view-node a))))
      (commands:run layout:zoom)
      (check-equal? (map id-of (list c echo)) (map id-of (layout:views)))
      (check (eq? c (layout:zoomed-view)))
      (test-user:settle)
      (check-equal? (list (cons (id-of c) #t) (cons (id-of echo) #f)) (layout-test/parts:drawn-views (test-user:client)))
      (layout:select! echo)
      (check-equal? (map id-of (list c echo)) (map id-of (layout:views)))
      (layout:select! b)
      (check-equal? (map id-of (list a b c echo)) (map id-of (layout:views)))
      (check-equal? #f (layout:zoomed-view))
      (commands:run layout:zoom)
      (check-equal? (map id-of (list b echo)) (map id-of (layout:views)))
      (commands:run layout:zoom)
      (check-equal? #f (layout:zoomed-view))
      (layout:delete-part! (layout:view-node echo)))))

(test "C-x o and the Super moves pass over a locked view"
  (let ([a (fresh notes)] [b (fresh mail)] [c (fresh notes)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column)) (layout-test/parts:atom a)
        (layout-test/parts:atom b '(locked . #t)) (layout-test/parts:atom c)))
    (layout:select! c)
    (check-equal? #f (layout:neighbour c (layout:direction down)))
    (check (eq? a (layout:neighbour c (layout:direction up))))
    (commands:run layout:other-view)
    (check (eq? a (layout:selected-view)))))

(test "C-x o alone in its level says there is no other view to select"
  (let ([said '()] [a (fresh notes)])
    (layout-test/parts:set-parts! (layout-test/parts:atom a))
    (layout:select! a)
    (options:set! ask:message-writer (lambda (text) (set! said (cons text said))))
    (test-user:press! "C-x o")
    (options:unset! ask:message-writer)
    (check-equal? '("No other view to select") said)
    (check (eq? a (layout:selected-view)))))

(define (first-name) (buffers:name (car (buffers:all))))

(test "a selection the user makes, and a switch, move the view's buffer to the front of the buffer list; the view chosen after a deletion does not"
  (let ([one (fresh (buffers:make "one" "one\n"))] [two (fresh (buffers:make "two" "two\n"))]
        [three (fresh (buffers:make "three" "three\n"))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (layout-test/parts:atom one) (layout-test/parts:atom two) (layout-test/parts:atom three)))
    (layout:select! two)
    (check-equal? "two" (first-name))
    (test-user:press! "C-x o")
    (check-equal? "three" (first-name))
    (test-user:press! "s-' j RET")
    (check-equal? '("two" "two") (list (layout-test/parts:selected-name) (first-name)))
    (layout:switch-to-buffer (buffers:find "one"))
    (check-equal? '("one" "two") (map buffers:name (list-head (buffers:all) 2)))
    (layout:select! three)
    (test-user:press! "C-x 2")
    (test-user:press! "C-x o")
    (buffers:move-to-front! (buffers:find "one"))
    (test-user:press! "C-c <left>")
    (check-equal? '("three" "three") (list (layout-test/parts:selected-name) (first-name)))
    (layout:select! one)
    (test-user:press! "C-x 0")
    (check-equal? '("three" "one") (list (layout-test/parts:selected-name) (first-name)))))
