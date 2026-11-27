(import (tuna) (test) (diff) (git) (git-test repositories) (git-status-test patches))

(define edges git-status-test/patches:edges)

(define (edge name) (cdr (assq name edges)))

(define (fresh-edge name)
  (let ([d (git-status-test/patches:fresh (symbol->string name))])
    (values d ((edge name) d) (git-status-test/patches:repository-of d))))

(test "bytes that are not UTF-8 stay as they were, and a user's apply.whitespace neither fixes nor refuses the selection"
  (check-equal? '(trials 52 failures ()) (git-status-test/patches:run-edges! '(latin1 latin1-staged whitespace-fix))))

(test "neither a user's diff prefixes nor a textconv driver changes the patch, and apply.whitespace error refuses nothing"
  (check-equal? '(trials 42 failures ()) (git-status-test/patches:run-edges! '(whitespace-error other-prefixes textconv))))

(test "lines and hunks of renamed, new and intent-to-add files"
  (check-equal? '(trials 46 failures ()) (git-status-test/patches:run-edges! '(rename-two-hunks new-file-staged new-file-intent-to-add))))

(test "lines and hunks of deleted files, and of a file whose mode changed"
  (check-equal? '(trials 46 failures ()) (git-status-test/patches:run-edges! '(deleted-unstaged deleted-staged mode-change))))

(test "staging one hunk of a file whose mode changed keeps the old mode"
  (let-values ([(d setup repo) (fresh-edge 'mode-change)])
    (let ([f (car (git:diff repo '()))])
      (git:apply repo (diff:hunks-patch f (list (car (diff:file-hunks f)))) '("--cached")))
    (check-equal? "100644 1567f14bd849f5b32f4393d226b06801cfa8a25b 0\tm.sh\n" (utf8->string (git:query repo '("ls-files" "-s"))))))

(test "a rename stays staged when a hunk of it is unstaged"
  (let-values ([(d setup repo) (fresh-edge 'rename-two-hunks)])
    (let ([f (car (git:diff repo '("--cached")))])
      (git:apply repo (diff:reverse-hunks-patch f (list (cadr (diff:file-hunks f)))) '("--reverse" "--cached")))
    (check-equal? "RM old.txt -> new.txt\n" (utf8->string (git:query repo '("status" "--short"))))))

(test "every selection at a missing final newline leaves what a line model gives"
  (check-equal? '(trials 96 failures ())
    (git-status-test/patches:run-edges! '(no-newline-append no-newline-change-last no-newline-added no-newline-removed no-newline-staged))))

(test "every selection in CRLF files and among blank lines, with diff.suppressBlankEmpty set, leaves what a line model gives"
  (check-equal? '(trials 52 failures ()) (git-status-test/patches:run-edges! '(crlf crlf-staged blank-lines))))

(test "paths git quotes, a path that is not UTF-8, and paths holding spaces"
  (check-equal? '(trials 42 failures ()) (git-status-test/patches:run-edges! '(quoted-tab quoted-quote-and-backslash latin1-path)))
  (check-equal? '(trials 70 failures ())
    (git-status-test/patches:run-edges! '(space-file space-folder-staged space-and-quote space-new-file space-deleted-file))))

(test "near repeated lines a patch keeps git's start on the side it applies to, so the hunk's own place is patched"
  (check-equal? '(trials 236 failures ()) (git-status-test/patches:run-edges! '(repeated-lines repeated-lines-staged)))
  (let-values ([(d setup repo) (fresh-edge 'repeated-lines-staged)])
    (let ([f (car (git:diff repo '("--cached")))])
      (check-equal? '("@@ -1,4 +1,14 @@" "@@ -19,7 +29,6 @@ x") (map (lambda (h) (utf8->string (diff:hunk-heading h))) (diff:file-hunks f)))
      (check-equal? "diff --git a/r.txt b/r.txt\n--- a/r.txt\n+++ b/r.txt\n@@ -29,7 +29,6 @@ x\n x\n x\n x\n-DEL\n x\n x\n x\n"
                    (utf8->string (diff:reverse-hunks-patch f (list (cadr (diff:file-hunks f)))))))))
