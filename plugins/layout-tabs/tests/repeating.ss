(import (tuna) (test) (test-user) (layout) (layout-tabs) (repeat) (views) (buffers) (keys) (tables)
        (layout-tabs-test parts))

(define atom layout-tabs-test/parts:atom)

(define (fresh name) (views:make (buffers:make (buffers:free-name name) (string-append name "\n"))))

(test "the keys that go on selecting tabs are a repeating keymap"
  (check (tables:ref keys:repeat-keymaps layout-tabs:switch-keymap #f)))

(test "with repeat loaded, C-x t o o selects the tab two on, and O the tab one back"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (layout-tabs-test/parts:set-parts! (layout-tabs:container '() (atom a) (atom b) (atom c)))
    (layout:select! a)
    (test-user:press! "C-x t o o")
    (check (eq? c (layout:selected-view)))
    (test-user:press! "O")
    (check (eq? b (layout:selected-view)))))

(test "with repeat loaded, C-x t O O selects the tab two back, and o the tab one on"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (layout-tabs-test/parts:set-parts! (layout-tabs:container '() (atom a) (atom b) (atom c)))
    (layout:select! a)
    (test-user:press! "C-x t O O")
    (check (eq? b (layout:selected-view)))
    (test-user:press! "o")
    (check (eq? c (layout:selected-view)))))
