(import (tuna) (test) (eval-test caught-reports) (test-runner) (test-user) (commands) (keys) (modes) (buffers) (views) (layout) (layout-split)
        (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(for-each (lambda (n) (dired-test:touch! (string-append "sp/" n ".txt") n "\n")) '("a" "b" "c" "d" "e"))

(define b (dired:visit (dired-test:home-path "sp")))

(layout:switch-to-buffer b)

(define (bound key)
  (views:call-with-view (layout:selected-view)
    (lambda () (commands:command-name (keys:lookup (test-user:client) key)))))

(test "a listing's mode derives from modes:special, and its hook sets buffers:revert-function to dired:refresh"
  (check (modes:derived? (modes:major-mode b) modes:special))
  (check (eq? dired:refresh (buffers:with-buffer b (buffers:revert-function)))))

(test "g, from the parent's keymap, and buffers:revert-buffer read the folder again, keeping marks"
  (dired-test:goto! "a.txt")
  (test-user:press! "m")
  (dired-test:touch! "sp/f.txt" "f\n")
  (dired-test:press-until-read! "g")
  (check-equal? '("  ." "  .." "* a.txt" "  b.txt" "  c.txt" "  d.txt" "  e.txt" "  f.txt") (dired-test:lines b))
  (dired-test:touch! "sp/g.txt" "g\n")
  (let ([version (buffers:version b)])
    (views:call-with-view (layout:selected-view) (lambda () (commands:run buffers:revert-buffer)))
    (test-runner:wait-until (lambda () (not (= version (buffers:version b))))))
  (check-equal? '("  ." "  .." "* a.txt" "  b.txt" "  c.txt" "  d.txt" "  e.txt" "  f.txt" "  g.txt") (dired-test:lines b)))

(test "digits and - come from the parent, so 3 n moves three entries"
  (dired-test:goto! "a.txt")
  (test-user:press! "3 n")
  (check-equal? "d.txt" (dired-test:point-name)))

(test "SPC, S-SPC, DEL, n and p keep the listing's own commands; g, q and < are the parent's"
  (check-equal? '(dired:next-line dired:previous-line dired:unmark-backward dired:next-line dired:previous-line
                  buffers:revert-buffer layout:quit-view editing:beginning-of-buffer)
    (map bound '("SPC" "S-SPC" "DEL" "n" "p" "g" "q" "<"))))

(test "a printing key the listing leaves unbound is undefined, and q quits the listing's view"
  (check-equal? '("z is undefined")
    (map condition-message (eval-test/caught-reports:during (lambda () (test-user:press! "z")))))
  (check-equal? '("  ." "  .." "* a.txt" "  b.txt" "  c.txt" "  d.txt" "  e.txt" "  f.txt" "  g.txt") (dired-test:lines b))
  (test-user:press! "q")
  (check-equal? '() (views:showing b)))
