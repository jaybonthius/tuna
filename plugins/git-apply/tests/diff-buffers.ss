(import (tuna) (test) (test-user) (options) (buffers) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-apply) (git-diff) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (press! keys) (git-status-test:press! keys))

(define (short . paths) (apply git-status-test:short "repo" paths))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(define (go! . identity) (apply git-status-test:go-to-section! identity))

(define (show! spec)
  (layout:select! (layout:display-buffer (git-diff:show repo spec '())))
  (git-status-test:settle!))

(test "s on a file of the unstaged diff stages it; the diff refreshes and point goes to the file that took its place"
  (show! (git-diff:unstaged-spec))
  (go! '(file . "a.py"))
  (press! "s")
  (check-equal? "M  a.py\n" (short "a.py"))
  (check-equal? "modified   b.txt" (git-status-test:point-line))
  (check (not (member "modified   a.py" (git-status-test:status)))))

(test "s on a hunk of the unstaged diff stages the hunk"
  (go! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt"))
  (press! "s")
  (check-equal? "MM long.txt\n" (short "long.txt")))

(test "u in the unstaged diff says Already unstaged; a placeholder off a change reads files"
  (go! '(file . "b.txt"))
  (refused 'git-apply:unstage "Already unstaged" "u"))

(test "u on a file of the staged diff unstages it; s there says Already staged; k discards the staged change, asking"
  (show! (git-diff:staged-spec))
  (go! '(file . "a.py"))
  (refused 'git-apply:stage "Already staged" "s")
  (press! "u")
  (check-equal? " M a.py\n" (short "a.py"))
  (go! '(file . "b.txt"))
  (git-status-test:answer! #t)
  (press! "k")
  (check-equal? '("Discard staged changes in \"b.txt\"? ") (git-status-test:take-asked!))
  (check-equal? " M b.txt\n" (short "b.txt")))

(test "a in the unstaged or staged diff says the change is already in the working tree"
  (show! (git-diff:unstaged-spec))
  (go! '(file . "a.py"))
  (refused 'git-apply:apply "Change is already in the working tree" "a"))

(test "v in the unstaged diff refuses: Cannot reverse unstaged changes"
  (refused 'git-apply:reverse "Cannot reverse unstaged changes" "v"))

(test "s and k on a committed diff refuse"
  (git-test/repositories:write-file! "repo/c.txt" "1\n2\n3\n")
  (git! "repo" "add" "c.txt")
  (git! "repo" "commit" "-qm" "c" "--" "c.txt")
  (git-test/repositories:write-file! "repo/c.txt" "1\n2\n3\n4\n")
  (git! "repo" "commit" "-qm" "four" "--" "c.txt")
  (show! (git-diff:range-spec "HEAD~1..HEAD"))
  (go! '(file . "c.txt"))
  (refused 'git-apply:stage "Cannot stage committed changes" "s")
  (refused 'git-apply:discard "Cannot discard committed changes" "k"))

(test "u on a committed file reverses it in the index and leaves the working tree; with git-apply:unstage-committed? #f it refuses"
  (press! "u")
  (check-equal? '("MM c.txt\n" "1\n2\n3\n") (list (short "c.txt") (git-status-test:git-out "repo" "show" ":c.txt")))
  (git! "repo" "reset" "-q" "--" "c.txt")
  (options:set! git-apply:unstage-committed? #f)
  (refused 'git-apply:unstage "Cannot unstage committed changes" "u")
  (options:unset! git-apply:unstage-committed?))

(test "v on a committed file asks Reverse \"FILE\"? and reverses it in the working tree; n changes nothing"
  (git-status-test:answer! #f)
  (refused 'git-mode:confirm "Abort" "v")
  (git-status-test:answer! #t)
  (press! "v")
  (check-equal? '("Reverse \"c.txt\"? " "Reverse \"c.txt\"? ") (git-status-test:take-asked!))
  (check-equal? "1\n2\n3\n" (git-status-test:read-file "repo/c.txt")))

(test "a on a committed hunk applies it to the working tree"
  (go! '(hunk . "@@ -1,3 +1,4 @@") '(file . "c.txt"))
  (press! "a")
  (check-equal? "1\n2\n3\n4\n" (git-status-test:read-file "repo/c.txt")))

(test "v with git-mode:no-confirm holding reverse asks nothing"
  (options:set! git-mode:no-confirm (list (git-mode:confirmation reverse)))
  (press! "v")
  (options:unset! git-mode:no-confirm)
  (check-equal? '() (git-status-test:take-asked!))
  (check-equal? "1\n2\n3\n" (git-status-test:read-file "repo/c.txt")))

(test "v where a hunk does not apply leaves a .rej file for it; with git-apply:reverse-atomically? nothing changes"
  (git-test/repositories:write-file! "repo/c.txt" "changed entirely\n")
  (options:set! git-apply:reverse-atomically? #t)
  (git-status-test:answer! #t)
  (press! "v")
  (check-equal? "changed entirely\n" (git-status-test:read-file "repo/c.txt"))
  (check (not (file-exists? (git-status-test:path "repo/c.txt.rej"))))
  (options:unset! git-apply:reverse-atomically?)
  (git-status-test:answer! #t)
  (press! "v")
  (check (file-exists? (git-status-test:path "repo/c.txt.rej")))
  (git-status-test:take-asked!))
