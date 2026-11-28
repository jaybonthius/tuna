(import (tuna) (test) (test-user) (options) (buffers) (document) (ui) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1..2 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,5 +1,4 @@\n one\n-two\n-three\n+TWO\n four\n+five\n-six\n"
    "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n+ OTHER\n  three\n"))

(define (line-attributes b)
  (map (lambda (e) (list (test-user:element-attribute e "data-layout") (test-user:element-attribute e "data-side")
                         (test-user:element-attribute e "style")))
       (begin (diff-sections-test:show-buffer! b) (diff-sections-test:drawn "diff-sections-line"))))

(test "a hunk's default rows: a context line both sides, the k-th removed line of a run beside the k-th added line after it, the rest alone"
  (check-equal? '#((1 . both) (2 . left) (3 . left) (2 . right) (4 . both) (5 . right) (6 . left))
                (diff-sections:hunk-rows (car (diff:file-hunks (car files))))))

(test "each line carries the layout and its row and side; the layout is unified until diff-sections:layout says otherwise"
  (let ([b (diff-sections-test:show! (diff-sections:file-section (car files)))])
    (check-equal? '("unified" "both" "--diff-sections-row: 1") (car (line-attributes b))))
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (let ([b (diff-sections-test:show! (diff-sections:file-section (car files)))])
    (check-equal? '(("split" "both" "--diff-sections-row: 1") ("split" "left" "--diff-sections-row: 2") ("split" "left" "--diff-sections-row: 3")
                    ("split" "right" "--diff-sections-row: 2"))
                  (list-head (line-attributes b) 4))
    (let ([lines " one\n-two\n-three\n+TWO\n four\n+five\n-six\n"] [t (diff-sections-test:text b)])
      (check-equal? lines (substring t (- (string-length t) (string-length lines)) (string-length t)))))
  (options:unset! diff-sections:layout)
  (check-raises assertion-violation? (options:set! diff-sections:layout 'columns)))

(test "a combined hunk is drawn unified whatever the layout"
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (let ([b (diff-sections-test:show! (diff-sections:file-section (cadr files)))])
    (check (for-all (lambda (a) (equal? "unified" (car a))) (line-attributes b))))
  (options:unset! diff-sections:layout))

(test "in two columns a context line's second copy is drawn, hidden from assistive technology, and is no text; in one column there is none"
  (let ([b (diff-sections-test:show! (diff-sections:file-section (car files)))])
    (check-equal? '() (diff-sections-test:drawn "diff-sections-copy")))
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (let ([b (diff-sections-test:show! (diff-sections:file-section (car files)))])
    (check-equal? '((" one" "true") (" four" "true"))
                  (map (lambda (e) (list (test-user:element-text e) (test-user:element-attribute e "aria-hidden")))
                       (diff-sections-test:drawn "diff-sections-copy"))))
  (options:unset! diff-sections:layout))

(test "with line numbers, each cell of two columns carries its own number: the old on the left, the new on the right, both on a context row"
  (options:set! diff-sections:line-numbers? #t)
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (diff-sections-test:show! (diff-sections:file-section (car files)))
  (check-equal? '(("1" "1") ("2") ("3") ("2") ("4" "3") ("4") ("5"))
                (map (lambda (line) (map test-user:element-text (test-user:elements line "diff-sections-cell-number")))
                     (diff-sections-test:drawn "diff-sections-line")))
  (options:unset! diff-sections:layout)
  (diff-sections-test:show! (diff-sections:file-section (car files)))
  (check-equal? '() (diff-sections-test:drawn "diff-sections-cell-number"))
  (options:unset! diff-sections:line-numbers?))
