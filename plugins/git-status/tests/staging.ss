(import (tuna) (test) (test-user) (hooks) (options) (buffers) (views) (layout) (layout-split) (editing) (files) (ui) (git) (git-mode)
        (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define (short) (git-status-test:short "repo"))

(define (cached file) (git-status-test:git-out "repo" "diff" "--cached" "--" file))

(define (point-line) (git-status-test:point-line))

(define (press! keys) (git-status-test:press! keys))

(define (go-to-section! . identity) (apply git-status-test:go-to-section! identity))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(define (select-line! text . identity)
  (apply git-status-test:go-to-in! text identity)
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (test-user:press! "C-e"))

(define (list-tail-string s from)
  (let loop ([i 0]) (if (string=? from (substring s i (+ i (string-length from)))) (substring s i (string-length s)) (loop (+ i 1)))))

(define (last-commands n) (map git:command-arguments (list-tail (git:commands repo) (- (length (git:commands repo)) n))))

(test "s on an unstaged file stages it and goes to the list's next file; u on a staged one unstages it, each command ending in git:command-ended"
  (go-to-section! '(file . "a.py") '(unstaged . #f))
  (press! "s")
  (check-equal? '("M  a.py\nMM b.txt\n D gone.txt\n M long.txt\n?? new.txt\n" "modified   b.txt") (list (short) (point-line)))
  (let* ([ended '()] [note (lambda (r c) (set! ended (cons (car (git:command-arguments c)) ended)))])
    (hooks:add! git:command-ended note)
    (go-to-section! '(file . "a.py") '(staged . #f))
    (press! "u")
    (hooks:remove! git:command-ended note)
    (check-equal? '(" M a.py\nMM b.txt\n D gone.txt\n M long.txt\n?? new.txt\n" "modified   b.txt" ("reset"))
                  (list (short) (point-line) ended))))

(test "s on an unstaged hunk stages its patch and goes to the file's next hunk; u on a staged hunk unstages it"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(unstaged . #f)))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(unstaged . #f))
  (press! "s")
  (check-equal? "@@ -1,5 +1,5 @@\n 1\n-2\n+TWO\n 3\n 4\n 5\n" (list-tail-string (cached "long.txt") "@@"))
  (check-equal? "@@ -15,6 +15,6 @@ TWO" (point-line))
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(staged . #f)))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(staged . #f))
  (press! "u")
  (check-equal? '("" "Staged changes (1)") (list (cached "long.txt") (point-line))))

(test "s and u with the region over lines of one hunk stage and unstage those lines alone; the region ends, and point goes to what is left of the hunk"
  (select-line! "+EIGHTEEN" '(file . "long.txt") '(unstaged . #f))
  (press! "s")
  (check-equal? "@@ -16,5 +16,6 @@\n 16\n 17\n 18\n+EIGHTEEN\n 19\n 20\n" (list-tail-string (cached "long.txt") "@@"))
  (check-equal? '(#f "@@ -15,7 +15,6 @@") (list (views:mark (git-status-test:view)) (point-line)))
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(staged . #f)))
  (select-line! "+EIGHTEEN" '(file . "long.txt") '(staged . #f))
  (press! "u")
  (check-equal? '("" #f) (list (cached "long.txt") (views:mark (git-status-test:view)))))

(test "s with the region over several hunks stages them in one patch, and over several files stages the files"
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(unstaged . #f))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (go-to-section! '(hunk . "@@ -15,6 +15,6 @@") '(file . "long.txt") '(unstaged . #f))
  (press! "s")
  (check-equal? '(" long.txt | 4 ++--\n 1 file changed, 2 insertions(+), 2 deletions(-)\n" #f)
                (list (git-status-test:git-out "repo" "diff" "--cached" "--stat" "--" "long.txt") (views:mark (git-status-test:view))))
  (go-to-section! '(file . "a.py") '(unstaged . #f))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (go-to-section! '(file . "b.txt") '(unstaged . #f))
  (press! "s")
  (check-equal? "M  a.py\nM  b.txt\n D gone.txt\nM  long.txt\n?? new.txt\n" (short)))

(test "s on a staged change, or on Staged changes, raises Already staged; u on Staged changes asks, as U does with unstaged changes too"
  (go-to-section! '(file . "b.txt") '(staged . #f))
  (refused 'git-status:stage "Already staged" "s")
  (go-to-section! '(staged . #f))
  (refused 'git-status:stage "Already staged" "s")
  (git-status-test:answer! #t)
  (press! "u")
  (check-equal? '(("Unstage all changes? ") " M a.py\n M b.txt\n D gone.txt\n M long.txt\n?? new.txt\n")
                (list (git-status-test:take-asked!) (short))))

(test "s on an untracked file stages it as a new file; u on one raises; C-u s stages it with intent to add, under Unstaged changes"
  (ui:show-section! (git-status-test:view) (git-status-test:section '(untracked . #f)))
  (go-to-section! '(file . "new.txt") '(untracked . #f))
  (press! "s")
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n M long.txt\nA  new.txt\n" (short))
  (git-test/repositories:write-file! "repo/newer.txt" "n\n")
  (git-mode:refresh-repository repo)
  (go-to-section! '(file . "newer.txt") '(untracked . #f))
  (refused 'git-status:unstage "Cannot unstage untracked changes" "u")
  (press! "C-u s")
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n M long.txt\nA  new.txt\n A newer.txt\n" (short))
  (check-equal? '("a.py" "b.txt" "gone.txt" "long.txt" "newer.txt")
                (map ui:section-value (ui:section-children (git-status-test:section '(unstaged . #f))))))

(test "u on an unstaged change raises Already unstaged, unless its file was staged with intent to add, which it unstages"
  (go-to-section! '(file . "a.py") '(unstaged . #f))
  (refused 'git-status:unstage "Already unstaged" "u")
  (go-to-section! '(file . "newer.txt") '(unstaged . #f))
  (press! "u")
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n M long.txt\nA  new.txt\n?? newer.txt\n" (short)))

(test "s on Untracked files stages every untracked file"
  (git-test/repositories:write-file! "repo/third.txt" "n\n")
  (git-mode:refresh-repository repo)
  (go-to-section! '(untracked . #f))
  (press! "s")
  (check-equal? " M a.py\n M b.txt\n D gone.txt\n M long.txt\nA  new.txt\nA  newer.txt\nA  third.txt\n" (short)))

(test "U with only staged changes unstages without asking, and raises Nothing to unstage with none"
  (git-test/repositories:git! "repo" "add" "-A")
  (git-mode:refresh-repository repo)
  (press! "U")
  (check-equal? '(() " M a.py\n M b.txt\n D gone.txt\n M long.txt\n?? new.txt\n?? newer.txt\n?? third.txt\n")
                (list (git-status-test:take-asked!) (short)))
  (refused 'git-status:unstage-all "Nothing to unstage" "U"))

(test "S stages every tracked change, asking Stage all changes? when something is staged; n does nothing; s on Unstaged changes is S; C-u S stages untracked files too"
  (press! "S")
  (check-equal? '(() "M  a.py\nM  b.txt\nD  gone.txt\nM  long.txt\n?? new.txt\n?? newer.txt\n?? third.txt\n")
                (list (git-status-test:take-asked!) (short)))
  (git-test/repositories:write-file! "repo/a.py" "more\n")
  (git-mode:refresh-repository repo)
  (git-status-test:answer! #f)
  (refused 'git-mode:confirm "Abort" "S")
  (check-equal? '(("Stage all changes? ") "MM a.py\nM  b.txt\nD  gone.txt\nM  long.txt\n?? new.txt\n?? newer.txt\n?? third.txt\n")
                (list (git-status-test:take-asked!) (short)))
  (go-to-section! '(unstaged . #f))
  (git-status-test:answer! #t)
  (press! "s")
  (check-equal? '(("Stage all changes? ") "M  a.py\nM  b.txt\nD  gone.txt\nM  long.txt\n?? new.txt\n?? newer.txt\n?? third.txt\n")
                (list (git-status-test:take-asked!) (short)))
  (git-status-test:answer! #t)
  (press! "C-u S")
  (check-equal? '(("Stage all changes? ") "M  a.py\nM  b.txt\nD  gone.txt\nM  long.txt\nA  new.txt\nA  newer.txt\nA  third.txt\n")
                (list (git-status-test:take-asked!) (short))))

(test "s on no change reads files to stage, Stage file,s: "
  (git-test/repositories:git! "repo" "reset" "-q")
  (git-test/repositories:write-file! "repo/z.txt" "z\n")
  (git-mode:refresh-repository repo)
  (press! "M-<")
  (git-status-test:answer! "z.txt,gone.txt")
  (press! "s")
  (check-equal? '(("Stage file,s: ") " M a.py\n M b.txt\nD  gone.txt\n M long.txt\nA  z.txt\n?? new.txt\n?? newer.txt\n?? third.txt\n")
                (list (git-status-test:take-asked!) (short))))

(test "with no context lines, a hunk command raises Not enough context; a whole file still stages"
  (options:set! git:diff-arguments '("-U0"))
  (git-mode:refresh-repository repo)
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "long.txt") '(unstaged . #f)))
  (go-to-section! '(hunk . "@@ -2 +2 @@") '(file . "long.txt") '(unstaged . #f))
  (refused 'git-status:stage "Not enough context to apply patch.  Increase the context" "s")
  (go-to-section! '(file . "long.txt") '(unstaged . #f))
  (press! "s")
  (check-equal? "M  long.txt\n" (git-status-test:short "repo" "long.txt"))
  (options:unset! git:diff-arguments))

(test "while the diff hides whitespace changes, s on a whole file applies its patch with --ignore-space-change, so those stay unstaged"
  (git-test/repositories:write-file! "repo/w.txt" "a b\nx\n")
  (git-test/repositories:git! "repo" "add" "w.txt")
  (git-test/repositories:git! "repo" "commit" "-qm" "w")
  (git-test/repositories:write-file! "repo/w.txt" "a  b\ny\n")
  (options:set! git:diff-arguments '("-w"))
  (git-mode:refresh-repository repo)
  (go-to-section! '(file . "w.txt") '(unstaged . #f))
  (press! "s")
  (options:unset! git:diff-arguments)
  (check-equal? "a b\ny\n" (git-status-test:git-out "repo" "show" ":w.txt"))
  (check-equal? '(("apply" "-p1" "--whitespace=nowarn" "--cached" "--ignore-space-change" "-")) (last-commands 1)))

(test "a binary file shows Binary files differ, and is staged, unstaged and discarded whole"
  (call-with-port (open-file-output-port (git-status-test:path "repo/bin.dat") (file-options no-fail)) (lambda (p) (put-bytevector p #vu8(0 1 2 0))))
  (git-test/repositories:git! "repo" "add" "bin.dat")
  (git-test/repositories:git! "repo" "commit" "-qm" "bin")
  (call-with-port (open-file-output-port (git-status-test:path "repo/bin.dat") (file-options no-fail)) (lambda (p) (put-bytevector p #vu8(0 3 2 0))))
  (git-mode:refresh-repository repo)
  (ui:show-section! (git-status-test:view) (git-status-test:section '(file . "bin.dat") '(unstaged . #f)))
  (check-equal? '("modified   bin.dat" "Binary files differ") (list-head (member "modified   bin.dat" (git-status-test:status)) 2))
  (go-to-section! '(file . "bin.dat") '(unstaged . #f))
  (press! "s")
  (check-equal? "M  bin.dat\n" (git-status-test:short "repo" "bin.dat"))
  (go-to-section! '(file . "bin.dat") '(staged . #f))
  (press! "u")
  (check-equal? " M bin.dat\n" (git-status-test:short "repo" "bin.dat"))
  (go-to-section! '(file . "bin.dat") '(unstaged . #f))
  (git-status-test:answer! #t)
  (press! "k")
  (check-equal? '(("Discard unstaged changes in \"bin.dat\"? ") "") (list (git-status-test:take-asked!) (git-status-test:short "repo" "bin.dat"))))
