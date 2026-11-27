(import (tuna) (test) (test-user) (options) (tables) (web) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1..2 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@ def\n one\n-two\n+TWO\n three\n@@ -9 +9 @@\n-nine\n+NINE\n"
    "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+cr" #xe8 "me\n+hello\n\\ No newline at end of file\n"))

(define b (diff-sections-test:show! (diff-sections:file-section (car files)) (diff-sections:file-section (cadr files))))

(define (line-faces) (map (lambda (e) (test-user:element-attribute e "data-face")) (diff-sections-test:drawn "diff-sections-line")))

(test "added and removed lines are drawn in diff.plus and diff.minus, context lines in diff-sections.context"
  (check-equal? '("diff-sections.context" "diff.minus" "diff.plus" "diff-sections.context" "diff.minus" "diff.plus" "diff.plus" "diff.plus")
                (line-faces))
  (check-equal? '(" one" "-two" "+TWO" " three" "-nine" "+NINE")
                (list-head (map test-user:element-text (diff-sections-test:drawn "diff-sections-text")) 6)))

(test "a missing final newline is drawn after its line in faces:shadow, and is no text"
  (let ([markers (diff-sections-test:drawn "diff-sections-no-newline")])
    (check-equal? '("\\ No newline at end of file") (map test-user:element-text markers))
    (check-equal? "shadow" (test-user:element-attribute (car markers) "data-face")))
  (let ([t (diff-sections-test:text b)] [n-txt "new file   n.txt\n@@ -0,0 +1,2 @@\n+cr\xfffc;me\n+hello\n"])
    (check-equal? n-txt (substring t (- (string-length t) (string-length n-txt)) (string-length t)))))

(test "a byte that is not UTF-8 is drawn as its octal escape"
  (check-equal? "+cr\\350me" (list-ref (map test-user:element-text (diff-sections-test:drawn "diff-sections-text")) 6)))

(test "the gutter of old and new line numbers is drawn only while diff-sections:line-numbers? holds"
  (check-equal? '() (diff-sections-test:drawn "diff-sections-numbers"))
  (options:set! diff-sections:line-numbers? #t)
  (let ([gutters (diff-sections-test:drawn "diff-sections-numbers")])
    (check-equal? '(("1" "1") ("2" "") ("" "2") ("3" "3") ("9" "") ("" "9") ("" "1") ("" "2"))
                  (map (lambda (g) (map test-user:element-text (filter (lambda (c) (and (pair? c) (eq? (car c) 'span))) (cdr g)))) gutters)))
  (options:unset! diff-sections:line-numbers?)
  (check-equal? '() (diff-sections-test:drawn "diff-sections-numbers"))
  (check-raises assertion-violation? (options:set! diff-sections:line-numbers? 'yes)))

(test "a combined hunk draws one prefix column per parent, each + or - in its face, under an unmerged file"
  (let ([cc (diff-sections-test:parse
              "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n+ OTHER\n  three\n")])
    (let ([b (diff-sections-test:show! (diff-sections:file-section (car cc)))])
      (check-equal? "unmerged   f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n+ OTHER\n  three\n" (diff-sections-test:text b))
      (let ([mine (list-ref (diff-sections-test:drawn "diff-sections-text") 2)])
        (check-equal? " +MINE" (test-user:element-text mine))
        (check-equal? '(("diff.plus" "+"))
          (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
               (test-user:elements-with mine "data-face")))))))

(test "the plugin's stylesheet is in web:stylesheets"
  (check-equal? "diff-sections/diff-sections.css" (tables:ref web:stylesheets 'diff-sections)))
