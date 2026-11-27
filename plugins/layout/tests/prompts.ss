(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-float) (editing) (echo-area) (minibuffer)
        (completion) (buffer-picker) (help) (status-line) (views) (buffers) (options) (tables) (commands) (keys)
        (layout-test parts) (layout-test focus))

(options:set! help:select-view? #t)

(define atom layout-test/parts:atom)
(define view-named layout-test/focus:view-named)
(define name! layout-test/focus:name!)
(define begin! layout-test/focus:begin!)
(define reset! layout-test/focus:reset!)
(define made-beside layout-test/focus:made-beside)
(define selected layout-test/focus:selected)
(define shown layout-test/focus:shown)
(define who layout-test/focus:who)
(define echo layout-test/focus:echo)
(define in-client layout-test/focus:in-client)
(define ask! layout-test/focus:ask!)
(define end-prompt! layout-test/focus:end-prompt!)
(define prompt-view layout-test/focus:prompt-view)

(define (click-part! v)
  (test-user:settle)
  (test-user:click-element! (layout-test/parts:view-element v)))

(define (click-status! v key)
  (test-user:settle)
  (test-user:click-element! (car (test-user:elements (layout-test/parts:view-element v) "status-line")) key))

(define (two!)
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (values a b)))

(define (raised thunk)
  (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))]) (thunk)))

(test "from the echo area, selected by code, C-x 0 refuses; C-x o goes to the view the user worked in, and a deletion there never selects the echo area"
  (let-values ([(a b) (two!)])
    (layout:select! (echo))
    (check-equal? '(layout:delete-view "a locked part") (raised (lambda () (in-client layout:delete-view))))
    (test-user:press! "C-x o")
    (check-equal? "a" (selected))
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))))

(test "window history from the echo area steps in the user's level"
  (let-values ([(a b) (two!)])
    (layout:select! (echo))
    (test-user:press! "C-c <left>")
    (check-equal? '("echo" ("a" "echo")) (list (selected) (shown)))))

(commands:define-command (show-x) "Shows the buffer x in the selected view." (layout:switch-to-buffer (buffers:find "x")))

(keys:bind! keys:global "C-c x" show-x)

(test "C-x 4 4 and a command that switches buffers, run from the echo area, show the buffer in the level's view selected least recently, and select it"
  (let-values ([(a b) (two!)])
    (or (buffers:find "x") (buffers:make "x" "x\n"))
    (layout:select! (echo))
    (test-user:press! "C-x 4 4 C-c x")
    (check-equal? '("b" "x") (list (selected) (buffers:name (views:buffer b))))))

(test "reset-layout from the echo area deletes the other views of the user's level and keeps a part placed outside it"
  (let* ([a (begin! "a")] [explorer (layout-test/focus:explorer!)] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (layout:select! (echo))
    (in-client layout:reset-layout)
    (check-equal? '("a" ("explorer" "a" "echo")) (list (selected) (shown)))))

(test "from a prompt, with a part placed beside the user's level, C-x o stays in the user's level"
  (let* ([a (begin! "a")] [explorer (layout-test/focus:explorer!)] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (test-user:press! "C-x o")
    (ask!)
    (test-user:press! "C-x o")
    (check-equal? "a" (selected))
    (end-prompt!)))

(test "q deletes the part a display made and selects the successor, the level's view selected most recently"
  (let-values ([(a b) (two!)])
    (let ([h (name! (in-client (lambda () (layout:display-buffer (buffers:make (buffers:free-name "h") "h\n") layout-split:display-below))) "h")])
      (layout:select! b)
      (layout:select! h)
      (in-client layout:quit-view)
      (check-equal? "b" (selected)))))

(test "the status line's mouse-3 selects the clicked view before deleting it, so a waiting prompt is left unselected"
  (let-values ([(a b) (two!)])
    (ask!)
    (click-status! a "<mouse-3>")
    (check-equal? '("b" #t) (list (selected) (and (minibuffer:current-prompt) #t)))
    (end-prompt!))
  (let-values ([(a b) (two!)])
    (click-status! a "<mouse-3>")
    (check-equal? '("b" ("b" "echo")) (list (selected) (shown)))))

(define (describe-car!)
  (in-client (lambda () (commands:run help:describe-name 'car (layout:selected-view))))
  (test-user:settle))

(test "q in *Help*, which help made and selected, deletes it and selects the view it was asked from, after a prompt in *Help* too"
  (let ([a (begin! "a")])
    (describe-car!)
    (check-equal? "*Help*" (selected))
    (test-user:press! "q")
    (check-equal? "a" (selected))
    (describe-car!)
    (layout-test/focus:prompt!)
    (check-equal? "*Help*" (selected))
    (test-user:press! "q")
    (check-equal? "a" (selected))))

(test "a nested level stands for its view used last that is not placed inside it: C-x o enters it there, and a display from beside it lands there"
  (let ([a (view-named "a")] [b (view-named "b")] [p (view-named "p")])
    (reset! (layout-split:container '((direction . row)) (atom a) (layout:level '() (layout-split:container '((direction . column)) (atom p '(depth . 50)) (atom b)))))
    (for-each layout:select! (list b p a))
    (test-user:press! "C-x o")
    (check-equal? "b" (selected))
    (layout:select! p)
    (layout:select! a)
    (check-equal? "b" (who (in-client (lambda () (layout:use-other-view (buffers:make (buffers:free-name "shown") "x\n"))))))))

(test "C-x o from a waiting prompt goes to the first view of the level the user was in; a deletion there selects the successor, which stays after C-g"
  (let-values ([(a b) (two!)])
    (ask!)
    (test-user:press! "C-x o")
    (check-equal? "a" (selected))
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))
    (end-prompt!)
    (check-equal? "b" (selected))))

(test "when the view a prompt started from goes by code, the prompt stays selected, and C-g selects the successor chosen then, recording no use"
  (let-values ([(a b) (two!)])
    (test-user:press! "C-x o")
    (ask!)
    (layout:delete-part! (layout:view-node b))
    (test-user:settle)
    (check-equal? " *Minibuf*" (selected))
    (let ([before (layout-test/focus:front 3)])
      (end-prompt!)
      (check-equal? "a" (selected))
      (check-equal? before (layout-test/focus:front 3)))))

(define (explorer-used-after!)
  (let* ([a (begin! "a")] [explorer (layout-test/focus:explorer!)] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (click-part! explorer)
    (click-part! a)
    (ask!)
    (layout:delete-part! (layout:view-node a))
    (test-user:settle)))

(test "a part beside the user's level, used after a new view was made, is never the successor of the view that left during a prompt; from the prompt, C-x o and C-M-v act in the successor's level"
  (explorer-used-after!)
  (check-equal? '(" *Minibuf*" "b" "explorer") (list-head (layout-test/focus:order) 3))
  (check-equal? "b" (who (in-client layout:other-view-for-scrolling)))
  (test-user:press! "C-x o")
  (check-equal? "b" (selected))
  (end-prompt!)
  (check-equal? "b" (selected))
  (explorer-used-after!)
  (end-prompt!)
  (check-equal? "b" (selected)))

(test "the same holds for a tab closed during a prompt"
  (let ([a (view-named "a")] [b (view-named "b")])
    (reset! (layout-tabs:container '() (atom a) (atom b)))
    (let ([explorer (layout-test/focus:explorer!)])
      (for-each layout:select! (list b explorer a))
      (ask!)
      (layout:delete-part! (layout:view-node a))
      (end-prompt!)
      (check-equal? "b" (selected)))))

(test "with prompts in a palette, the palette's removal selects the successor"
  (tables:set! layout:display-rules minibuffer:buffer? layout-float:display-palette)
  (let-values ([(a b) (two!)])
    (ask!)
    (check (layout:popup-node (prompt-view)))
    (layout:delete-part! (layout:view-node a))
    (end-prompt!)
    (check-equal? "b" (selected)))
  (explorer-used-after!)
  (end-prompt!)
  (check-equal? "b" (selected))
  (tables:remove! layout:display-rules minibuffer:buffer?))

(test "from a prompt opened while the echo area was selected, C-M-v scrolls the view the user worked in, and C-x o lists that view's level"
  (let-values ([(a b) (two!)])
    (test-user:press! "C-x o")
    (layout:select! (echo))
    (ask!)
    (check-equal? "b" (who (in-client layout:other-view-for-scrolling)))
    (test-user:press! "C-x o")
    (check-equal? "a" (selected))
    (end-prompt!)))

(test "C-x 1 from a prompt or the echo area refuses, as from any locked part"
  (let-values ([(a b) (two!)])
    (ask!)
    (check-equal? '(layout:zoom "a locked part") (raised (lambda () (in-client (lambda () (layout:zoom #f))))))
    (end-prompt!)
    (layout:select! (echo))
    (check-equal? '(layout:zoom "a locked part") (raised (lambda () (in-client (lambda () (layout:zoom #f))))))
    (check-equal? #f (layout:zoomed-view))))

(test "a display from a prompt uses the view of the user's level selected least recently, and the prompt stays selected"
  (let-values ([(a b) (two!)])
    (test-user:press! "C-x o C-x o")
    (ask!)
    (check-equal? "b" (who (in-client (lambda () (layout:display-buffer (buffers:make (buffers:free-name "x") "x\n"))))))
    (check-equal? " *Minibuf*" (selected))
    (end-prompt!))
  (let-values ([(a b) (two!)])
    (test-user:press! "C-x o C-x o")
    (ask!)
    (check-equal? "b" (who (in-client (lambda () (layout:use-other-view (buffers:make (buffers:free-name "x") "x\n"))))))
    (check-equal? " *Minibuf*" (selected))
    (end-prompt!)))

(test "a prompt shown in the selected view by a display rule sets other-view on it, so its successor becomes the view the user works in, and the selection stays"
  (tables:set! layout:display-rules minibuffer:buffer? layout:display-in-selected-view)
  (let-values ([(a b) (two!)])
    (ask!)
    (check-equal? '("a" "a") (list (selected) (who (prompt-view))))
    (check-equal? "b" (who (in-client layout:other-view-for-scrolling)))
    (test-user:press! "C-x o")
    (check-equal? "b" (selected))
    (end-prompt!))
  (tables:remove! layout:display-rules minibuffer:buffer?))

(test "C-x k RET kills the buffer and deletes no view"
  (let-values ([(a b) (two!)])
    (test-user:press! "C-x k RET")
    (check-equal? '("a" ("a" "b" "echo" " *Minibuf*") #f) (list (selected) (shown) (buffers:find "a")))))

(test "reloading layout while a prompt waits keeps the prompt selected"
  (let ([a (begin! "a")])
    (ask!)
    (load-module! '(layout))
    (check-equal? " *Minibuf*" (selected))
    (end-prompt!)
    (check-equal? "a" (selected))))
