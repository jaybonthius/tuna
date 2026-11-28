(import (tuna) (test) (test-user) (layout) (layout-split) (repeat) (views) (buffers)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)

(define (weight v) (cdr (assq 'weight (layout-split-test/parts:attributes-of v))))

(test "with repeat loaded, C-x } } } { enlarges three times and shrinks once, and a key the user adds to the resize keymap repeats too"
  (let ([a (views:make (buffers:make (buffers:free-name "a") ""))] [b (views:make (buffers:make (buffers:free-name "b") ""))])
    (layout-split-test/parts:set-parts! (layout-split:container '((direction . row)) (atom a) (atom b)))
    (layout:select! a)
    (test-user:press! "C-x } } } {")
    (check-equal? '(7/5 3/5) (list (weight a) (weight b)))
    (keys:bind! layout-split:resize-keymap "s" layout-split:shrink)
    (test-user:press! "C-x } s s")
    (check-equal? '(6/5 4/5) (list (weight a) (weight b)))))

(test "with repeat loaded, C-x ^ ^ v makes the view taller twice and shorter once, as Emacs's resize-window-repeat-map does"
  (let ([a (views:make (buffers:make (buffers:free-name "a") ""))] [b (views:make (buffers:make (buffers:free-name "b") ""))])
    (layout-split-test/parts:set-parts! (layout-split:container '((direction . column)) (atom a) (atom b)))
    (layout:select! a)
    (test-user:press! "C-x ^ ^ v")
    (check-equal? '(6/5 4/5) (list (weight a) (weight b)))))
