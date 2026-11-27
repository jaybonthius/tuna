(import (tuna) (test) (views) (ui) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,4 +1,4 @@\n one\n-two\n+TWO\n three\n-four\n+FOUR\n"
    "diff --git a/b.py b/b.py\n--- a/b.py\n+++ b/b.py\n@@ -1 +1 @@\n-b\n+B\n"
    "diff --git a/c.py b/c.py\n--- a/c.py\n+++ b/c.py\n@@ -1 +1 @@\n-c\n+C\n\\ No newline at end of file\n"))

(define b (apply diff-sections-test:show! (map diff-sections:file-section files)))

(define v (diff-sections-test:view))

(define (at line column) (+ (diff-sections-test:line-position b line) column))

(define (line-at p)
  (let-values ([(hunk index) (diff-sections:line-at v p)])
    (list (and hunk (ui:section-value hunk)) index)))

(define (selected from to)
  (views:set-mark! v from)
  (views:set-point! v to)
  (let-values ([(hunk first last) (diff-sections:selected-lines v)])
    (list (and hunk (ui:section-value hunk)) first last)))

(test "line-at gives the hunk section and the index of the line at a position; a heading is no line, and a line followed by a missing newline's marker is a line"
  (check-equal? '((#f #f) (#f #f) ("@@ -1,4 +1,4 @@" 0) ("@@ -1,4 +1,4 @@" 1) ("@@ -1,4 +1,4 @@" 2) ("@@ -1,4 +1,4 @@" 5) (#f #f) ("@@ -1 +1 @@" 0))
    (map (lambda (line) (line-at (at line 1))) '("modified   a.py" "@@ -1,4 +1,4 @@" " one" "-two" "+TWO" "+FOUR" "modified   b.py" "-b")))
  (check-equal? '("@@ -1 +1 @@" 1) (line-at (at "+C" 1)))
  (views:set-point! v (at "-two" 2))
  (let-values ([(hunk index) (diff-sections:line-at v)])
    (check-equal? '(hunk 1) (list (ui:section-type hunk) index)))
  (check-raises assertion-violation? (diff-sections:line-at 'v)))

(test "selected-lines gives the hunk and the first and last lines the region touches; the end's line counts only when the region reaches into its text"
  (check-equal? '("@@ -1,4 +1,4 @@" 1 2) (selected (at "-two" 0) (at "+TWO" 2)))
  (check-equal? '("@@ -1,4 +1,4 @@" 1 2) (selected (at "-two" 1) (at " three" 0)))
  (check-equal? '("@@ -1,4 +1,4 @@" 0 4) (selected (at " one" 0) (at "-four" 1))))

(test "a region across hunks, or reaching a heading, selects no lines, and neither does no region"
  (check-equal? '(#f #f #f) (selected (at "-two" 0) (at "-b" 1)))
  (check-equal? '(#f #f #f) (selected (at "@@ -1,4 +1,4 @@" 0) (at "-two" 1)))
  (views:set-mark! v #f)
  (check-equal? '(#f #f #f) (call-with-values (lambda () (diff-sections:selected-lines v)) list)))

(test "the selection gives what a partial patch takes: the hunk read back from the buffer and its file"
  (selected (at "-two" 0) (at "+TWO" 2))
  (let-values ([(hunk first last) (diff-sections:selected-lines v)])
    (check-equal? "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,4 +1,4 @@\n one\n-two\n+TWO\n three\n four\n"
      (utf8->string (diff:lines-patch (diff-sections:file hunk b) (diff-sections:hunk hunk) first last))))
  (views:set-mark! v #f))
