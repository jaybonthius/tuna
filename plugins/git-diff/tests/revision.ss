(import (tuna) (test) (test-user) (options) (hooks) (keys) (buffers) (document) (views) (layout) (layout-split) (editing) (ui) (git) (git-mode)
        (git-status) (git-diff) (transient-test) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define (press! keys) (git-status-test:press! keys))

(define (visible) (git-status-test:status))

(define (rev-of name) (let ([out (git-status-test:git-out "repo" "rev-parse" name)]) (substring out 0 (- (string-length out) 1))))

(define root (rev-of "HEAD~2"))

(define second (rev-of "HEAD~1"))

(define (show! revision)
  (layout:select! (layout:display-buffer (git-diff:show-revision repo revision '())))
  (git-status-test:settle!))

(define (starting-with prefix) (filter (lambda (l) (and (>= (string-length l) (string-length prefix)) (string=? prefix (substring l 0 (string-length prefix))))) (visible)))

(test "a root commit has no Parent row, and its files are all new"
  (show! root)
  (check-equal? '() (starting-with "Parent:"))
  (check-equal? '("new file   a.py" "new file   b.txt" "new file   gone.txt") (starting-with "new file")))

(test "the message is text lines as written, trailers plain"
  (git! "repo" "commit" "-q" "--allow-empty" "-m" "Summary line\n\nThe body [WIP] here.\n\nSigned-off-by: Tuna <tuna@example.org>")
  (show! "HEAD")
  (let ([shown (buffers:document (views:buffer (git-status-test:view)))])
    (check (git-status-test:contains? (document:text shown) "Summary line\n\nThe body [WIP] here.\n\nSigned-off-by: Tuna <tuna@example.org>\n"))
    (check-equal? '("Summary line" "The body [WIP] here." "Signed-off-by: Tuna <tuna@example.org>") (list-head (member "Summary line" (visible)) 3))))

(test "a merge commit shows its two parents and its combined diff"
  (git-test/repositories:conflict! "merged")
  (git! "merged" "add" "f.txt")
  (git! "merged" "commit" "-qm" "merge")
  (let ([merged (git:find-repository (git-status-test:path "merged"))])
    (layout:select! (layout:display-buffer (git-diff:show-revision merged "HEAD" '())))
    (git-status-test:settle!)
    (check-equal? 2 (length (starting-with "Parent:")))
    (check (pair? (starting-with "@@@")))))

(test "a user's diff.noPrefix and diff.mnemonicPrefix do not change what is parsed"
  (git! "repo" "config" "diff.noPrefix" "true")
  (git! "repo" "config" "diff.mnemonicPrefix" "true")
  (show! root)
  (check-equal? '("new file   a.py" "new file   b.txt" "new file   gone.txt") (starting-with "new file"))
  (git! "repo" "config" "--unset" "diff.noPrefix")
  (git! "repo" "config" "--unset" "diff.mnemonicPrefix"))

(test "a change in the working tree leaves the commit buffer as it was"
  (show! root)
  (let ([before (visible)])
    (git-test/repositories:write-file! "repo/a.py" "worktree change\n")
    (git-mode:refresh-repository repo)
    (git-status-test:settle!)
    (check-equal? before (visible))))

(test "git-diff:revision-headers chooses the header lines, and git-diff:related-refs '() shows no related rows"
  (options:set! git-diff:revision-headers (list (git-diff:header author) (git-diff:header author-date)))
  (options:set! git-diff:related-refs '())
  (show! second)
  (check-equal? '() (starting-with "Commit:"))
  (check-equal? 1 (length (starting-with "Author:")))
  (check-equal? '() (append (starting-with "Parent:") (starting-with "Contained:") (starting-with "Merged:")))
  (options:unset! git-diff:revision-headers git-diff:related-refs))

(test "an entry of git-diff:revision-sections adds its sections after the diff"
  (let ([entry (lambda (revision) (list (ui:section '((type . note) (value . #f)) (string-append "Note on " revision))))])
    (hooks:add! git-diff:revision-sections entry)
    (show! second)
    (hooks:remove! git-diff:revision-sections entry)
    (check (pair? (starting-with "Note on ")))))

(test "j in a commit buffer away from a file shows the jump menu: headers, message, diffstat, diff"
  (show! second)
  (press! "M-<")
  (press! "j")
  (check-equal? '("Jump to" (("h" "Headers") ("m" "Message") ("s" "Diffstat") ("d" "Diff"))) (transient-test:menu))
  (press! "m")
  (check-equal? "Second commit" (git-status-test:point-line))
  (press! "j d")
  (check-equal? "modified   a.py" (git-status-test:point-line))
  (press! "j")
  (check-equal? "a.py | 1" (git-status-test:point-line))
  (press! "M-< j h")
  (check-equal? (ui:section-heading-start (git-status-test:section '(headers . #f))) (views:point (git-status-test:view)))
  (press! "M-< j s")
  (check-equal? "1 file changed, 1 insertion(+)" (git-status-test:point-line)))

(test "SPC, S-SPC and DEL in a diff or commit buffer are the ordinary scrolls"
  (show! second)
  (check-equal? (list views:scroll-up views:scroll-down views:scroll-down)
                (views:call-with-view (git-status-test:view)
                  (lambda () (map (lambda (k) (keys:lookup (test-user:client) k)) '("SPC" "S-SPC" "DEL"))))))

(test "d c with -- files limits the commit buffer to them, and they are its git-mode:files; D F drops them and brings them back"
  (git-status-test:answer! "a.py" second)
  (press! "d - - C-u c")
  (check-equal? '("modified   a.py") (starting-with "modified"))
  (check-equal? '("a.py") (buffers:with-buffer (views:buffer (git-status-test:view)) (git-mode:files)))
  (press! "D F")
  (check-equal? '() (buffers:with-buffer (views:buffer (git-status-test:view)) (git-mode:files)))
  (press! "D F")
  (check-equal? '("modified   a.py") (starting-with "modified")))
