(import (tuna) (test) (test-user) (layout) (layout-split) (repeat) (views) (buffers) (keys) (tables)
        (layout-test parts))

(define atom layout-test/parts:atom)

(define (named name) (buffers:make (buffers:free-name name) (string-append name "\n")))

(test "the keys that go on through a view's buffers and through the other views are repeating keymaps"
  (check (tables:ref keys:repeat-keymaps layout:buffer-navigation-keymap #f))
  (check (tables:ref keys:repeat-keymaps layout:other-view-keymap #f)))

(test "with repeat loaded, C-x <left> <left> goes back two buffers and <right> forward one"
  (let ([one (named "one")] [two (named "two")] [three (named "three")])
    (let ([v (views:make one)])
      (layout-test/parts:set-parts! (atom v))
      (layout:select! v)
      (layout:switch-to-buffer two)
      (layout:switch-to-buffer three)
      (test-user:press! "C-x <left> <left>")
      (check (eq? one (views:buffer v)))
      (test-user:press! "<right>")
      (check (eq? two (views:buffer v))))))

(test "with repeat loaded, C-x o o moves two views on, and O back one"
  (let ([a (views:make (named "a"))] [b (views:make (named "b"))] [c (views:make (named "c"))])
    (layout-test/parts:set-parts! (layout-split:container '((direction . row)) (atom a) (atom b) (atom c)))
    (layout:select! a)
    (test-user:press! "C-x o o")
    (check (eq? c (layout:selected-view)))
    (test-user:press! "O")
    (check (eq? b (layout:selected-view)))))
