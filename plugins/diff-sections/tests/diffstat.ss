(import (tuna) (test) (test-user) (buffers) (document) (ui) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1..2 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n@@ -9 +9 @@\n-nine\n+NINE\n"
    "diff --git a/long/name.txt b/long/name.txt\nnew file mode 100644\nindex 0000000..3\n--- /dev/null\n+++ b/long/name.txt\n@@ -0,0 +1 @@\n+x\n"
    "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n"))

(define (lines text)
  (let loop ([cs (string->list text)] [line '()] [acc '()])
    (cond
      [(null? cs) (reverse (if (null? line) acc (cons (list->string (reverse line)) acc)))]
      [(char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse (cons #\newline line))) acc))]
      [else (loop (cdr cs) (cons (car cs) line) acc)])))

(ui:define-section-kind stat-kind)

(define (stat-text files) (diff-sections-test:text (diff-sections-test:show! (diff-sections:diffstat-section files))))

(test "the diffstat's heading counts files, insertions and deletions, in the singular for one, with no clause for none"
  (check-equal? "3 files changed, 3 insertions(+), 2 deletions(-)\n" (car (lines (stat-text files))))
  (check-equal? "1 file changed, 1 insertion(+)\n" (car (lines (stat-text (list (cadr files))))))
  (check-equal? "1 file changed\n" (car (lines (stat-text (list (caddr files)))))))

(test "a row per file: its path padded to the longest, the count right-aligned, Bin for a binary file"
  (check-equal? '("a.py          |   4\n" "long/name.txt |   1\n" "x.bin         | Bin\n") (cdr (lines (stat-text files)))))

(test "each row is a section of type file whose value is the path, inside a section of type diffstat"
  (let* ([b (diff-sections-test:show! (diff-sections:diffstat-section files))] [stat (car (ui:top-sections b))])
    (check-equal? '(diffstat ((file . "a.py") (file . "long/name.txt") (file . "x.bin")))
                  (list (ui:section-type stat) (map (lambda (s) (cons (ui:section-type s) (ui:section-value s))) (ui:section-children stat))))))

(test "the bar after each count is drawn in diff.plus and diff.minus, scaled to the largest change, and is no text"
  (diff-sections-test:show! (diff-sections:diffstat-section files))
  (let ([bars (diff-sections-test:drawn "diff-sections-stat-bar")])
    (check-equal? '(("++" "--") ("+" "") ("" ""))
                  (map (lambda (bar) (map test-user:element-text (test-user:elements-with bar "data-face"))) bars))
    (check-equal? '("diff.plus" "diff.minus")
                  (map (lambda (e) (test-user:element-attribute e "data-face")) (test-user:elements-with (car bars) "data-face")))
    (check-equal? "true" (test-user:element-attribute (car bars) "aria-hidden"))))

(test "a diffstat's rows are file sections of their files, made by the maker given, with the attributes given"
  (let* ([b (diff-sections-test:show! (diff-sections:diffstat-section files '((revision . "HEAD")) stat-kind))]
         [rows (ui:section-children (car (ui:top-sections b)))])
    (check-equal? '(("a.py" "a.py" "HEAD") ("long/name.txt" "long/name.txt" "HEAD") ("x.bin" "x.bin" "HEAD"))
                  (map (lambda (r) (list (ui:section-value r) (diff:file-path (diff-sections:file r b)) (document:node-attribute r 'revision)))
                       rows))
    (check (for-all (lambda (r) (eq? (document:node-kind r) (document:node-kind (car rows)))) rows))
    (check-equal? '() (ui:section-children (car rows)))))
