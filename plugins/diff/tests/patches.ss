(import (tuna) (test) (diff))

(define (parse . lines) (diff:parse (string->utf8 (apply string-append lines))))

(define (text bytes) (utf8->string bytes))

(define (raised thunk)
  (guard (c [(or (error? c) (assertion-violation? c)) (condition-message c)])
    (thunk)
    'nothing-raised))

(define one-line-change
  (car (parse "diff --git a/a.py b/a.py\n" "index 1f2e3d4..5a6b7c8 100644\n" "--- a/a.py\n" "+++ b/a.py\n"
              "@@ -1,3 +1,3 @@\n" " one\n" "-two\n" "+TWO\n" " three\n")))

(define two-hunks
  (parse "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n"
         "@@ -1,2 +1,3 @@\n a\n+new\n b\n"
         "@@ -10,3 +11,3 @@\n j\n-k\n+K\n l\n"))

(test "a file's patch is its header as git wrote it and every hunk"
  (check-equal? "diff --git a/a.py b/a.py\nindex 1f2e3d4..5a6b7c8 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"
    (text (diff:file-patch one-line-change))))

(test "a lines patch keeps removed lines outside the range as context and drops added ones, and counts again"
  (check-equal? "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,3 +1,2 @@\n one\n-two\n three\n"
    (text (diff:lines-patch one-line-change (car (diff:file-hunks one-line-change)) 1 1))))

(test "a reverse lines patch keeps added lines outside the range as context and drops removed ones"
  (check-equal? "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,2 +1,3 @@\n one\n+TWO\n three\n"
    (text (diff:reverse-lines-patch one-line-change (car (diff:file-hunks one-line-change)) 2 2))))

(test "a lines patch of lines that change nothing raises"
  (check-equal? "no change in these lines"
    (raised (lambda () (diff:lines-patch one-line-change (car (diff:file-hunks one-line-change)) 0 0)))))

(test "a hunks patch moves its new starts by the hunks left out; a reverse one keeps git's new starts and moves the old"
  (let ([f (car two-hunks)])
    (check-equal? "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -10,3 +10,3 @@\n j\n-k\n+K\n l\n"
      (text (diff:hunks-patch f (cdr (diff:file-hunks f)))))
    (check-equal? "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -11,3 +11,3 @@\n j\n-k\n+K\n l\n"
      (text (diff:reverse-hunks-patch f (cdr (diff:file-hunks f)))))))

(test "hunks are a file's by value, and must be contiguous and in order"
  (let ([f (car two-hunks)] [copy (car (parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n+new\n b\n"))])
    (check-equal? "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n+new\n b\n"
      (text (diff:hunks-patch f (diff:file-hunks copy))))
    (check-equal? "not hunks of this file, contiguous and in order"
      (raised (lambda () (diff:hunks-patch f (reverse (diff:file-hunks f))))))
    (check-equal? "not hunks of this file" (raised (lambda () (diff:hunks-patch f '(x)))))))

(test "a partial patch's header is a modification of the new path, unless it selects every change of an added file"
  (let ([added (car (parse "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3b18e51\n--- /dev/null\n+++ b/n.txt\n"
                           "@@ -0,0 +1,2 @@\n+hello\n+there\n"))]
        [renamed (car (parse "diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\n"
                             "index 1..2 100644\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-c\n+d\n"))])
    (check-equal? "diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n@@ -0,0 +1,1 @@\n+hello\n"
      (text (diff:lines-patch added (car (diff:file-hunks added)) 0 0)))
    (check-equal? "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..3b18e51\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+hello\n+there\n"
      (text (diff:lines-patch added (car (diff:file-hunks added)) 0 1)))
    (check-equal? "diff --git a/new.txt b/new.txt\n--- a/new.txt\n+++ b/new.txt\n@@ -1,1 +1,1 @@\n-c\n+d\n"
      (text (diff:hunks-patch renamed (diff:file-hunks renamed))))))

(test "a path git would quote is C-quoted in a partial patch's header, its prefix inside the quotes, and a TAB after a name is not kept"
  (let ([quoted (parse
                  "diff --git \"a/tab\\there.txt\" \"b/tab\\there.txt\"\n--- \"a/tab\\there.txt\"\n+++ \"b/tab\\there.txt\"\n@@ -1 +1 @@\n-a\n+b\n"
                  "diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n")])
    (check-equal? "diff --git \"a/tab\\there.txt\" \"b/tab\\there.txt\"\n--- \"a/tab\\there.txt\"\n+++ \"b/tab\\there.txt\"\n@@ -1,1 +1,1 @@\n-a\n+b\n"
      (text (diff:lines-patch (car quoted) (car (diff:file-hunks (car quoted))) 0 1)))
    (check-equal? "diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\n+++ b/my file.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n"
      (text (diff:lines-patch (cadr quoted) (car (diff:file-hunks (cadr quoted))) 0 1)))))

(test "binary files and combined diffs get no partial patch"
  (let ([binary (car (parse "diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n"))]
        [combined (car (parse "diff --cc f.txt\nindex 1,2..0\n--- a/f.txt\n+++ b/f.txt\n@@@ -1,1 -1,1 +1,2 @@@\n  one\n++two\n"))])
    (check-equal? "binary files have no hunks" (raised (lambda () (diff:hunks-patch binary '()))))
    (check-equal? "Cannot un-/stage resolution hunks.  Stage the whole file"
      (raised (lambda () (diff:lines-patch combined (car (diff:file-hunks combined)) 1 1))))))
