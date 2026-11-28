(import (tuna) (test) (test-runner) (diff) (diff parse))

(define (parse . lines) (diff:parse (string->utf8 (apply string-append lines))))

(define (summary file)
  (list (diff:file-old-path file) (diff:file-new-path file) (diff:file-status file)
        (diff:file-binary? file) (diff:file-combined? file) (length (diff:file-hunks file))))

(define (lines-of hunk)
  (map (lambda (line)
         (list (diff:line-kind line) (utf8->string (diff:line-prefix line)) (utf8->string (diff:line-bytes line))
               (diff:line-no-newline? line)))
       (vector->list (diff:hunk-lines hunk))))

(define (first-hunk files) (car (diff:file-hunks (car files))))

(define (numbers hunk index) (call-with-values (lambda () (diff:line-numbers hunk index)) list))

(define (raised thunk)
  (guard (c [(or (error? c) (assertion-violation? c)) (list (condition-who c) (condition-message c) (condition-irritants c))])
    (thunk)
    'nothing-raised))

(define one-line-change
  (parse "diff --git a/a.py b/a.py\n" "index 1f2e3d4..5a6b7c8 100644\n" "--- a/a.py\n" "+++ b/a.py\n"
         "@@ -1,3 +1,3 @@\n" " one\n" "-two\n" "+TWO\n" " three\n"))

(test "a git diff of one changed line gives its file, with its paths, blobs, modes and header as git wrote them"
  (check-equal? 1 (length one-line-change))
  (let ([a (car one-line-change)])
    (check (diff:file? a))
    (check (not (diff:file? 'a)))
    (check-equal? '("a.py" "a.py" "a.py" modified #f #f 1)
      (cons (diff:file-path a) (summary a)))
    (check-equal? '("1f2e3d4" "5a6b7c8" "100644" "100644")
      (list (diff:file-old-blob a) (diff:file-new-blob a) (diff:file-old-mode a) (diff:file-new-mode a)))
    (check-equal? (string->utf8 "a.py") (diff:file-path-bytes a))
    (check-equal? (string->utf8 "a.py") (diff:file-old-path-bytes a))
    (check-equal? "diff --git a/a.py b/a.py\nindex 1f2e3d4..5a6b7c8 100644\n--- a/a.py\n+++ b/a.py\n"
      (utf8->string (diff:file-header a)))))

(test "a hunk keeps its @@ line's starts and counts, its heading, and its lines by kind and prefix"
  (let ([h (first-hunk one-line-change)])
    (check (diff:hunk? h))
    (check-equal? '(1 3 1 3) (list (diff:hunk-old-start h) (diff:hunk-old-count h) (diff:hunk-new-start h) (diff:hunk-new-count h)))
    (check-equal? "@@ -1,3 +1,3 @@" (utf8->string (diff:hunk-heading h)))
    (check (diff:line? (vector-ref (diff:hunk-lines h) 0)))
    (check-equal? '((context " " "one" #f) (removed "-" "two" #f) (added "+" "TWO" #f) (context " " "three" #f)) (lines-of h))))

(test "diff:line-numbers gives a context line both numbers, a removed line the old alone and an added line the new alone"
  (let ([h (first-hunk one-line-change)])
    (check-equal? '(1 1) (numbers h 0))
    (check-equal? '(2 #f) (numbers h 1))
    (check-equal? '(#f 2) (numbers h 2))
    (check-equal? '(3 3) (numbers h 3))))

(test "renames, copies, mode and type changes, new, deleted and binary files each get their status, paths and modes"
  (let ([many (parse
                "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n"
                "diff --git a/c.txt b/d.txt\nsimilarity index 90%\ncopy from c.txt\ncopy to d.txt\nindex 1..2 100644\n--- a/c.txt\n+++ b/d.txt\n@@ -1 +1 @@\n-c\n+d\n"
                "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n"
                "diff --git a/link b/link\nold mode 100644\nnew mode 120000\n"
                "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3b18e51\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+hello\n"
                "diff --git a/g.txt b/g.txt\ndeleted file mode 100644\nindex 3b18e51..0000000\n--- a/g.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-hello\n"
                "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n")])
    (check-equal? '(("old.txt" "new.txt" renamed #f #f 0) ("c.txt" "d.txt" copied #f #f 1) ("run.sh" "run.sh" modified #f #f 0)
                    ("link" "link" type-changed #f #f 0) (#f "n.txt" added #f #f 1) ("g.txt" #f deleted #f #f 1)
                    ("x.bin" "x.bin" modified #t #f 0))
      (map summary many))
    (check-equal? '((#f #f) ("100644" "100644") ("100644" "100755") ("100644" "120000") (#f "100644") ("100644" #f) ("100644" "100644"))
      (map (lambda (f) (list (diff:file-old-mode f) (diff:file-new-mode f))) many))
    (check-equal? "g.txt" (diff:file-path (list-ref many 5)))
    (check-equal? #f (diff:file-old-path-bytes (list-ref many 4)))))

(test "the no-newline marker is a flag of the line before it, and a CR before the LF is part of the line"
  (check-equal? '((context " " "a" #f) (removed "-" "b" #t) (added "+" "B" #t))
    (lines-of (first-hunk (parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n"
                                 "\\ No newline at end of file\n+B\n\\ No newline at end of file\n"))))
  (check-equal? '((removed "-" "a\r" #f) (added "+" "b\r" #f))
    (lines-of (first-hunk (parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\r\n+b\r\n")))))

(test "a C-quoted path is unquoted, a TAB git adds after a name holding a space is dropped, and a path's bytes are kept"
  (let ([quoted (parse
                  "diff --git \"a/tab\\there.txt\" \"b/tab\\there.txt\"\n--- \"a/tab\\there.txt\"\n+++ \"b/tab\\there.txt\"\n@@ -1 +1 @@\n-a\n+b\n"
                  "diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n"
                  "diff --git \"a/caf\\351.txt\" \"b/caf\\351.txt\"\nold mode 100644\nnew mode 100755\n")])
    (check-equal? '("tab\there.txt" "my file.txt" "caf\xFFFD;.txt") (map diff:file-path quoted))
    (check-equal? (list (string->utf8 "tab\there.txt") (string->utf8 "my file.txt") (bytevector 99 97 102 233 46 116 120 116))
      (map diff:file-path-bytes quoted))))

(test "diff -u's own format, whose names end in a TAB and a date, is read, and a removed line that reads like a header is the hunk's"
  (check-equal? '(("a.txt" "b.txt" modified #f #f 1))
    (map summary (parse "--- a.txt\t2026-01-01 00:00:00\n+++ b.txt\t2026-01-02 00:00:00\n@@ -1,2 +1,2 @@\n one\n--- two\n+++ two\n")))
  (check-equal? '((removed "-" "-- a/x" #f) (context " " "one" #f))
    (lines-of (first-hunk (parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n--- a/x\n one\n")))))

(test "a conflicted file's combined diff and git diff --cached's unmerged line are unmerged and combined"
  (let ([conflicted (parse "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,7 @@@\n  one\n"
                           "++<<<<<<< HEAD\n +MINE\n++=======\n+ OTHER\n++>>>>>>> other\n  three\n* Unmerged path g.txt\n")])
    (check-equal? '(("f.txt" "f.txt" unmerged #f #t 1) ("g.txt" "g.txt" unmerged #f #t 0)) (map summary conflicted))
    (let ([h (first-hunk conflicted)])
      (check-equal? '((context "  " "one" #f) (added "++" "<<<<<<< HEAD" #f) (added " +" "MINE" #f) (added "++" "=======" #f)
                      (added "+ " "OTHER" #f) (added "++" ">>>>>>> other" #f) (context "  " "three" #f))
        (lines-of h))
      (check-equal? '(1 3 1 7) (list (diff:hunk-old-start h) (diff:hunk-old-count h) (diff:hunk-new-start h) (diff:hunk-new-count h))))))

(test "what is not a unified diff raises with the first line it could not read, and an empty diff has no files"
  (check-equal? '(diff:parse "not a unified diff" ("hello")) (raised (lambda () (parse "hello\n"))))
  (check-equal? '(diff:parse "not a unified diff" ("@@ -1,2 +1,2 @@"))
    (raised (lambda () (parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n"))))
  (check-equal? '(diff:parse "not a bytevector" ("text")) (raised (lambda () (diff:parse "text"))))
  (check-equal? '() (diff:parse #vu8()))
  (check-equal? '(diff:file-path "not a file diff" (x)) (raised (lambda () (diff:file-path 'x)))))

(test "the job's library parses on any thread, as diff:parse does"
  (let ([text (string->utf8 "diff --git a/f b/f\nold mode 100644\nnew mode 100755\n")])
    (check-equal? (diff:parse text) (test-runner:join (fork-task (lambda (restore) (parse-diff text)))))))

(test "diff:file-line-counts gives the added and the removed lines of a file; a combined line counts where any column marks it"
  (check-equal? '(1 1) (call-with-values (lambda () (diff:file-line-counts (car one-line-change))) list))
  (let ([files (parse "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n"
                      "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n"
                      "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,3 -1,3 +1,4 @@@\n  one\n++<<<<<<< HEAD\n +MINE\n- OTHER\n  three\n")])
    (check-equal? '((2 0) (0 0) (2 1)) (map (lambda (f) (call-with-values (lambda () (diff:file-line-counts f)) list)) files)))
  (check-raises assertion-violation? (diff:file-line-counts 'no)))
