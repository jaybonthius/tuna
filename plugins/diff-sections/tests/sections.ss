(import (tuna) (test) (test-user) (hooks) (buffers) (document) (views) (ui) (diff) (diff-sections) (diff-sections-test))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1..2 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@ def\n one\n-two\n+TWO\n three\n@@ -9 +9 @@\n-nine\n+NINE\n"
    "diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\nindex 1..2 100644\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-o\n+n\n"
    "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+hello\n\\ No newline at end of file\n"
    "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n"
    "diff --git \"a/caf\\351.txt\" \"b/caf\\351.txt\"\ndeleted file mode 100644\nindex 4..0000000\n--- \"a/caf\\351.txt\"\n+++ /dev/null\n@@ -1 +0,0 @@\n-cr" #xe8 "me\n"))

(define b (apply diff-sections-test:show! (map diff-sections:file-section files)))

(define (rebuild-edits! buffer datums)
  (let* ([edits 0] [count! (lambda (edited edit) (when (eq? edited buffer) (set! edits (+ edits 1))))])
    (hooks:add! buffers:after-edit count!)
    (buffers:reconcile! buffer (document:token (buffers:document buffer) 0) datums)
    (hooks:remove! buffers:after-edit count!)
    edits))

(test "a file section's heading is its status word padded to 11 characters and its path; inside it a hunk section per hunk, its heading the @@ line and its body the lines as text"
  (check-equal? (string-append
                  "modified   a.py\n@@ -1,3 +1,3 @@ def\n one\n-two\n+TWO\n three\n@@ -9 +9 @@\n-nine\n+NINE\n"
                  "renamed    old.txt -> new.txt\n@@ -1 +1 @@\n-o\n+n\n"
                  "new file   n.txt\n@@ -0,0 +1 @@\n+hello\n"
                  "modified   x.bin\nBinary files differ\n"
                  "deleted    caf\xfffc;.txt\n@@ -1 +0,0 @@\n-cr\xfffc;me\n")
                (diff-sections-test:text b))
  (let ([a (ui:find-section b '((file . "a.py")))] [hunk (ui:find-section b '((hunk . "@@ -1,3 +1,3 @@ def") (file . "a.py")))])
    (check-equal? '(file "a.py") (list (ui:section-type a) (ui:section-value a)))
    (check-equal? '(hunk "@@ -1,3 +1,3 @@ def") (list (ui:section-type hunk) (ui:section-value hunk)))
    (check-equal? '("@@ -1,3 +1,3 @@ def" "@@ -9 +9 @@") (map ui:section-value (ui:section-children a)))))

(test "the status words are Magit's"
  (let ([word (lambda parts (diff-sections:status-word (car (apply diff-sections-test:parse parts))))])
    (check-equal? '("modified" "renamed" "new file" "modified" "deleted") (map diff-sections:status-word files))
    (check-equal? "copied" (word "diff --git a/a.txt b/b.txt\nsimilarity index 100%\ncopy from a.txt\ncopy to b.txt\n"))
    (check-equal? "typechange" (word "diff --git a/l b/l\nold mode 100644\nnew mode 120000\n"))
    (check-equal? "unmerged" (word "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,1 -1,1 +1,1 @@@\n- a\n -b\n++c\n"))))

(test "a file section keeps its file diff, a hunk section its hunk; a hunk section's file needs its buffer"
  (let ([a (ui:find-section b '((file . "a.py")))] [hunk (ui:find-section b '((hunk . "@@ -1,3 +1,3 @@ def") (file . "a.py")))])
    (check-equal? (car files) (diff-sections:file a))
    (check-equal? (car (diff:file-hunks (car files))) (diff-sections:hunk hunk))
    (check-equal? (car files) (diff-sections:file hunk b))
    (check-raises (lambda (c) (and (assertion-violation? c) (string=? "a hunk section's file needs its buffer" (condition-message c))))
      (diff-sections:file hunk))
    (check-raises (lambda (c) (and (assertion-violation? c) (string=? "not a hunk section" (condition-message c))))
      (diff-sections:hunk a))))

(test "hunk-section makes a hunk's section alone"
  (let* ([f (car files)] [h (cadr (diff:file-hunks f))] [s (diff-sections:hunk-section f h)]
         [d (document:from-datum s)])
    (check-equal? "@@ -9 +9 @@\n-nine\n+NINE\n" (document:text d))
    (check-raises assertion-violation? (diff-sections:hunk-section f 'h))
    (check-raises assertion-violation? (diff-sections:hunk-section 'f h))))

(test "a byte that is not UTF-8 is a raw-byte atom whose byte is the line's own, in a line and in a path"
  (check-equal? '(233 232) (diff-sections-test:raw-bytes b))
  (let ([moved (diff-sections-test:parse
                 "diff --git \"a/old\\351.txt\" b/new.txt\nsimilarity index 100%\nrename from \"old\\351.txt\"\nrename to new.txt\n")])
    (let ([m (diff-sections-test:show! (diff-sections:file-section (car moved)))])
      (check-equal? "renamed    old\xfffc;.txt -> new.txt\n" (diff-sections-test:text m))
      (check-equal? '(233) (diff-sections-test:raw-bytes m)))))

(test "rebuilding from the same diffs edits nothing, a combined diff's columns included"
  (check-equal? 0 (rebuild-edits! b (map diff-sections:file-section files)))
  (let* ([conflicted (diff-sections-test:parse
                       "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n+ OTHER\n  three\n")]
         [cc (diff-sections-test:show! (diff-sections:file-section (car conflicted)))])
    (check-equal? 0 (rebuild-edits! cc (list (diff-sections:file-section (car conflicted)))))))

(test "a file section takes extra attributes, such as its first visibility, and raises for what is no file diff"
  (let ([c (diff-sections-test:show! (diff-sections:file-section (car files) '((hidden . #t))))])
    (check (ui:section-hidden? (diff-sections-test:view) (ui:find-section c '((file . "a.py"))))))
  (check-raises (lambda (c) (and (assertion-violation? c) (string=? "not a file diff" (condition-message c))))
    (diff-sections:file-section 'x))
  (check-raises assertion-violation? (diff-sections:file-section (car files) '(hidden))))

(test "a hunk added to a hidden file section stays hidden with it"
  (let* ([one-hunk (diff-sections-test:parse "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n")]
         [two-hunks (diff-sections-test:parse
                      "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n@@ -20,3 +20,3 @@\n x\n-y\n+Y\n z\n")]
         [grown (diff-sections-test:show! (diff-sections:file-section (car one-hunk)))]
         [v (diff-sections-test:view)])
    (ui:hide-section! v (ui:find-section grown '((file . "a.py"))))
    (buffers:reconcile! grown (document:token (buffers:document grown) 0) (list (diff-sections:file-section (car two-hunks))))
    (let ([file (ui:find-section grown '((file . "a.py")))])
      (check (ui:section-hidden? v file))
      (check-equal? 2 (length (ui:section-children file)))
      (check-equal? '() (diff-sections-test:drawn "diff-sections-line")))))
