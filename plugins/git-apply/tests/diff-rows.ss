(import (tuna) (test) (test-user) (options) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-apply) (git-diff) (diff-sections) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (press! keys) (git-status-test:press! keys))

(define (short . paths) (apply git-status-test:short "repo" paths))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(define (show! spec)
  (layout:select! (layout:display-buffer (git-diff:show repo spec '())))
  (git-status-test:settle!))

(define (button heading title)
  (test-user:settle)
  (let ([h (find (lambda (e) (git-status-test:contains? (test-user:element-text e) heading))
                 (test-user:elements (git-status-test:drawn) "ui-section-heading"))])
    (find (lambda (b) (equal? title (test-user:element-attribute b "title"))) (test-user:elements h "git-apply-button"))))

(test "a click on a file's stage button in the unstaged diff stages that file, whatever point is"
  (show! (git-diff:unstaged-spec))
  (press! "M-<")
  (let ([view (git-status-test:view)] [point (views:point (git-status-test:view))])
    (test-user:click-element! (button "modified   long.txt" "Stage"))
    (git-status-test:settle!)
    (check-equal? "M  long.txt\n" (short "long.txt"))
    (check-equal? (list view point) (list (git-status-test:view) (views:point (git-status-test:view))))))

(test "a click on a file's unstage button in the staged diff unstages it"
  (show! (git-diff:staged-spec))
  (test-user:click-element! (button "modified   long.txt" "Unstage"))
  (git-status-test:settle!)
  (check-equal? " M long.txt\n" (short "long.txt")))

(test "in two columns the region follows the text: from the first removed line to the second it holds those two lines, not the added lines beside them"
  (git-test/repositories:write-file! "repo/two.txt" "a\nb\nc\n")
  (git! "repo" "add" "two.txt")
  (git! "repo" "commit" "-qm" "two" "--" "two.txt")
  (git-test/repositories:write-file! "repo/two.txt" "A\nB\nc\n")
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (show! (git-diff:unstaged-spec))
  (git-status-test:go-to-in! "-a" '(file . "two.txt"))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (git-status-test:go-to-in! "-b" '(file . "two.txt"))
  (test-user:press! "C-e")
  (press! "s")
  (options:unset! diff-sections:layout)
  (check-equal? "@@ -1,3 +1 @@\n-a\n-b\n c\n" (let* ([out (git-status-test:git-out "repo" "diff" "--cached" "--" "two.txt")]
                                                     [at (let loop ([i 0]) (if (char=? #\@ (string-ref out i)) i (loop (+ i 1))))])
                                                (substring out at (string-length out)))))

(test "v on a binary file of a committed diff says Cannot reverse binary files"
  (call-with-port (open-file-output-port (git-status-test:path "repo/bin.dat") (file-options no-fail))
    (lambda (p) (put-bytevector p #vu8(0 1 2 0))))
  (git! "repo" "add" "bin.dat")
  (git! "repo" "commit" "-qm" "bin" "--" "bin.dat")
  (show! (git-diff:range-spec "HEAD~1..HEAD"))
  (git-status-test:go-to-section! '(file . "bin.dat"))
  (git-status-test:answer! #t)
  (refused 'git-apply:reverse "Cannot reverse binary files" "v"))

(test "S in a diff buffer limited to files stages the modified ones among them alone; U in a staged diff limited to files unstages those alone"
  (git! "repo" "reset" "-q")
  (show! (git-diff:range-spec "HEAD" '("a.py" "long.txt")))
  (press! "S")
  (check-equal? "M  a.py\n M b.txt\n D gone.txt\nM  long.txt\n" (short "a.py" "b.txt" "gone.txt" "long.txt"))
  (git! "repo" "add" "b.txt" "gone.txt")
  (show! (git-diff:range-spec "HEAD" '("a.py")))
  (git-status-test:answer! #t)
  (press! "U")
  (check-equal? " M a.py\nM  b.txt\nD  gone.txt\nM  long.txt\n" (short "a.py" "b.txt" "gone.txt" "long.txt")))

(test "a click on a diffstat row's stage button stages that row's file"
  (git! "repo" "reset" "-q")
  (show! (git-diff:unstaged-spec))
  (test-user:click-element! (button "a.py     | 4" "Stage"))
  (git-status-test:settle!)
  (check-equal? "M  a.py\n" (short "a.py")))

(test "S in a diff buffer limited to a file stages that file alone, also after a diff git refused left the buffer as it was"
  (git! "repo" "reset" "-q")
  (show! (git-diff:range-spec "HEAD" '("a.py")))
  (check-raises git:failed-condition? (git-diff:show repo (git-diff:range-spec "no-such-ref") '()))
  (check (git-diff:spec=? (git-diff:range-spec "HEAD" '("a.py")) (git-diff:buffer-spec (views:buffer (git-status-test:view)))))
  (press! "S")
  (check-equal? "M  a.py\n M b.txt\n" (short "a.py" "b.txt")))
