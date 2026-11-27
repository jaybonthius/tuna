(import (tuna) (test) (test-user) (options) (buffers) (document) (views) (layout) (layout-split) (editing) (files) (ui) (git)
        (git-mode) (git-status) (git-status-test) (git-test repositories))

(define repo (git-status-test:fresh! "repo"))

(define git! git-test/repositories:git!)

(define write-file! git-test/repositories:write-file!)

(define (short . paths) (apply git-status-test:short "repo" paths))

(define (read-file name) (git-status-test:read-file (string-append "repo/" name)))

(define (press! keys) (git-status-test:press! keys))

(define (go-to-section! . identity) (apply git-status-test:go-to-section! identity))

(define (asked) (git-status-test:take-asked!))

(define (refused who message keys) (check-equal? (list (list who message)) (git-status-test:press-reporting! keys)))

(define (refresh!) (git-mode:refresh-repository repo))

(define (discard! answer keys)
  (git-status-test:answer! answer)
  (press! keys))

(define (last-commands r n) (map git:command-arguments (list-tail (git:commands r) (- (length (git:commands r)) n))))

(define numbers git-status-test:numbers)

(define one-to-twenty (numbers 1 20))

(test "k on an unstaged hunk asks Discard hunk?; n raises Abort and changes nothing; y reverse-applies it to the working tree, point going as for s"
  (git-status-test:show-files! '(unstaged . #f))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(unstaged . #f))
  (git-status-test:answer! #f)
  (refused 'git-mode:confirm "Abort" "k")
  (check-equal? '(("Discard hunk? ") " M a.py\nMM b.txt\n D gone.txt\n M long.txt\n?? new.txt\n") (list (asked) (short)))
  (discard! #t "k")
  (check-equal? (list '("Discard hunk? ") (string-append (numbers 1 17) "EIGHTEEN\n19\n20\n") "@@ -15,6 +15,6 @@")
                (list (asked) (read-file "long.txt") (git-status-test:point-line))))

(test "k with the region over lines of an unstaged hunk asks Discard region? and discards them; the region ends"
  (git-status-test:go-to-in! "+EIGHTEEN" '(file . "long.txt") '(unstaged . #f))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (test-user:press! "C-e")
  (discard! #t "k")
  (check-equal? (list '("Discard region? ") (string-append (numbers 1 17) "19\n20\n") #f "@@ -15,6 +15,5 @@")
                (list (asked) (read-file "long.txt") (views:mark (git-status-test:view)) (git-status-test:point-line))))

(test "k on several hunks asks once, naming the file"
  (write-file! "repo/long.txt" (string-append "1\nTWO\n" (numbers 3 17) "EIGHTEEN\n19\n20\n"))
  (refresh!)
  (git-status-test:show-files! '(unstaged . #f))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(unstaged . #f))
  (views:set-mark! (git-status-test:view) (views:point (git-status-test:view)))
  (go-to-section! '(hunk . "@@ -15,6 +15,6 @@") '(file . "long.txt") '(unstaged . #f))
  (discard! #t "k")
  (check-equal? (list '("Discard 2 hunks from long.txt? ") one-to-twenty) (list (asked) (read-file "long.txt"))))

(test "k on a staged hunk of a file with no unstaged change reverse-applies it to the index and the working tree at once"
  (write-file! "repo/long.txt" (string-append "1\nTWO\n" (numbers 3 20)))
  (git! "repo" "add" "long.txt")
  (refresh!)
  (git-status-test:show-files! '(staged . #f))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? (list '("Discard hunk? ") "" one-to-twenty) (list (asked) (short "long.txt") (read-file "long.txt")))
  (check-equal? '(("apply" "-p1" "--whitespace=nowarn" "--reverse" "--index" "-")) (last-commands repo 1)))

(test "k on a staged hunk of a file with unstaged changes too goes to the index, then to the working tree with --reject"
  (write-file! "repo/long.txt" (string-append "1\nTWO\n" (numbers 3 20)))
  (git! "repo" "add" "long.txt")
  (write-file! "repo/long.txt" (string-append "1\nTWO\n" (numbers 3 19) "TWENTY\n"))
  (refresh!)
  (git-status-test:show-files! '(staged . #f))
  (go-to-section! '(hunk . "@@ -1,5 +1,5 @@") '(file . "long.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? (list '("Discard hunk? ") " M long.txt\n" (string-append (numbers 1 19) "TWENTY\n"))
                (list (asked) (short "long.txt") (read-file "long.txt")))
  (check-equal? '(("apply" "-p1" "--whitespace=nowarn" "--reverse" "--cached" "-") ("apply" "-p1" "--whitespace=nowarn" "--reverse" "--reject" "-"))
                (last-commands repo 2)))

(test "k on an unstaged modified file restores it from the index"
  (go-to-section! '(file . "a.py") '(unstaged . #f))
  (discard! #t "k")
  (check-equal? '(("Discard unstaged changes in \"a.py\"? ") "") (list (asked) (short "a.py"))))

(test "k on a staged modified file reverse-applies its staged change to the index and the working tree, so its unstaged change stays"
  (go-to-section! '(file . "b.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Discard staged changes in \"b.txt\"? ") " M b.txt\n" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\nETA\ntheta\n")
                (list (asked) (short "b.txt") (read-file "b.txt"))))

(test "k on a deleted file resurrects it"
  (go-to-section! '(file . "gone.txt") '(unstaged . #f))
  (discard! #t "k")
  (check-equal? '(("Resurrect \"gone.txt\"? ") "bye\n") (list (asked) (read-file "gone.txt"))))

(test "k on a staged deletion resurrects it in the index alone, so an edit since stays; a plain staged deletion becomes an unstaged one"
  (git! "repo" "rm" "-q" "--cached" "b.txt")
  (write-file! "repo/b.txt" "MY EDIT\n")
  (refresh!)
  (go-to-section! '(file . "b.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Resurrect \"b.txt\"? ") " M b.txt\n" "MY EDIT\n") (list (asked) (short "b.txt") (read-file "b.txt")))
  (git! "repo" "checkout" "-q" "--" "b.txt")
  (git! "repo" "rm" "-q" "gone.txt")
  (refresh!)
  (go-to-section! '(file . "gone.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? (list '("Resurrect \"gone.txt\"? ") " D gone.txt\n" #f)
                (list (asked) (short "gone.txt") (file-exists? (git-status-test:path "repo/gone.txt")))))

(test "k on a new file changed since it was staged takes it out of the index and keeps it"
  (git! "repo" "checkout" "-q" "--" "gone.txt")
  (write-file! "repo/am.txt" "one\n")
  (git! "repo" "add" "am.txt")
  (write-file! "repo/am.txt" "one\ntwo\n")
  (refresh!)
  (go-to-section! '(file . "am.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Discard staged changes in \"am.txt\"? ") "?? am.txt\n" "one\ntwo\n") (list (asked) (short "am.txt") (read-file "am.txt")))
  (delete-file (git-status-test:path "repo/am.txt")))

(test "k on an untracked file deletes it, or moves it to the trash while files:delete-by-moving-to-trash? holds; on Untracked files it asks once, listing them"
  (for-each (lambda (n) (write-file! (string-append "repo/" n) "x\n")) '("n1.txt" "n2.txt" "n3.txt"))
  (refresh!)
  (git-status-test:show-files! '(untracked . #f))
  (go-to-section! '(file . "n1.txt") '(untracked . #f))
  (discard! #t "k")
  (check-equal? '(("Delete \"n1.txt\"? ") #f) (list (asked) (file-exists? (git-status-test:path "repo/n1.txt"))))
  (check (not (member "n1.txt" (git-status-test:status))))
  (options:set! files:delete-by-moving-to-trash? #t)
  (go-to-section! '(file . "n2.txt") '(untracked . #f))
  (discard! #t "k")
  (check-equal? '(("Trash \"n2.txt\"? ") #f #t)
                (list (asked) (file-exists? (git-status-test:path "repo/n2.txt")) (file-exists? (git-status-test:path ".local/share/Trash/files/n2.txt"))))
  (go-to-section! '(untracked . #f))
  (discard! #t "k")
  (check-equal? '(("n3.txt\nnew.txt\nTrash 2 files? ") #f #f)
                (list (asked) (file-exists? (git-status-test:path "repo/n3.txt")) (file-exists? (git-status-test:path "repo/new.txt"))))
  (options:unset! files:delete-by-moving-to-trash?))

(test "k on a staged rename asks to undo it; with the new file deleted it unstages both paths; with the original's folder gone it makes it again"
  (git! "repo" "mv" "b.txt" "moved.txt")
  (refresh!)
  (go-to-section! '(file . "moved.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Undo rename b.txt -> moved.txt? ") " M long.txt\n") (list (asked) (short)))
  (git! "repo" "mv" "b.txt" "moved.txt")
  (delete-file (git-status-test:path "repo/moved.txt"))
  (refresh!)
  (go-to-section! '(file . "moved.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Undo rename b.txt -> moved.txt? ") " D b.txt\n M long.txt\n") (list (asked) (short)))
  (git! "repo" "checkout" "-q" "--" "b.txt")
  (write-file! "repo/old/x.txt" "x\n")
  (git! "repo" "add" "old")
  (git! "repo" "commit" "-qm" "old")
  (mkdir (git-status-test:path "repo/new"))
  (git! "repo" "mv" "old/x.txt" "new/x.txt")
  (delete-directory (git-status-test:path "repo/old"))
  (refresh!)
  (check (not (file-directory? (git-status-test:path "repo/old"))))
  (go-to-section! '(file . "new/x.txt") '(staged . #f))
  (discard! #t "k")
  (check-equal? '(("Undo rename old/x.txt -> new/x.txt? ") " M long.txt\n" "x\n") (list (asked) (short) (read-file "old/x.txt")))
  (git! "repo" "reset" "-q" "--soft" "HEAD~1")
  (git! "repo" "rm" "-q" "-r" "-f" "old"))

(test "k on a list of mixed kinds asks once per kind, in Magit's order, and n stops with Abort"
  (delete-file (git-status-test:path "repo/gone.txt"))
  (write-file! "repo/a.py" "x\n")
  (refresh!)
  (go-to-section! '(unstaged . #f))
  (git-status-test:answer! #t #f)
  (refused 'git-mode:confirm "Abort" "k")
  (check-equal? '(("Resurrect \"gone.txt\"? " "Discard unstaged changes in 2 files? ") " M a.py\n M long.txt\n") (list (asked) (short))))

(test "k on a commit, or on what is no change, raises"
  (git-status-test:go-to-in! "Second commit" '(unpushed . "@{upstream}"))
  (refused 'git-status:discard "Cannot discard committed changes" "k")
  (press! "M-<")
  (refused 'git-status:discard "Cannot apply this, it's not a change" "k"))

(test "an action in git-mode:no-confirm runs without its question"
  (options:set! git-mode:no-confirm (list (git-mode:confirmation discard)))
  (go-to-section! '(file . "a.py") '(unstaged . #f))
  (press! "k")
  (options:unset! git-mode:no-confirm)
  (check-equal? '(() "") (list (asked) (short "a.py"))))

(test "a path starting with ~ is refused"
  (write-file! "repo/~tilde" "t\n")
  (refresh!)
  (git-status-test:show-files! '(untracked . #f))
  (go-to-section! '(file . "~tilde") '(untracked . #f))
  (refused 'git-status:discard "Refusing to delete \"~tilde\", too dangerous" "k")
  (check (file-exists? (git-status-test:path "repo/~tilde"))))

(test "a discard reverts the unmodified buffers visiting the files it changed, and leaves a modified one with its edits"
  (write-file! "repo/a.py" "changed\n")
  (write-file! "repo/long.txt" (string-append one-to-twenty "changed\n"))
  (let ([a (files:visit (git-status-test:path "repo/a.py"))] [long (files:visit (git-status-test:path "repo/long.txt"))])
    (buffers:insert! long 1 "edit\n")
    (git-status-test:answer! #f)
    (refresh!)
    (go-to-section! '(unstaged . #f))
    (git-status-test:answer! #t #f)
    (press! "k")
    (check-equal? '("Save file ~/repo/long.txt? " "Discard unstaged changes in 2 files? " "Save file ~/repo/long.txt? ") (asked))
    (check-equal? (list (read-file "a.py") "edit\n")
                  (list (document:text (buffers:document a)) (substring (document:text (buffers:document long)) 0 5)))
    (buffers:set-modified! long #f)
    (buffers:kill! long)))

(test "k on Staged changes reverses the files with no unstaged change in one patch, and those with some in another, so their unstaged work stays"
  (let ([lists (git-status-test:fresh! "lists")])
    (git! "lists" "add" "a.py" "long.txt")
    (write-file! "lists/long.txt" (string-append (git-status-test:read-file "lists/long.txt") "extra\n"))
    (git-mode:refresh-repository lists)
    (go-to-section! '(staged . #f))
    (let ([before (length (git:commands lists))])
      (discard! #t "k")
      (check-equal? (list '("Discard staged changes in 3 files? ") " M b.txt\n D gone.txt\n M long.txt\n?? new.txt\n"
                          "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\nETA\ntheta\n" (string-append one-to-twenty "extra\n"))
                    (list (asked) (git-status-test:short "lists") (git-status-test:read-file "lists/b.txt") (git-status-test:read-file "lists/long.txt")))
      (check-equal? '(("apply" "-p1" "--whitespace=nowarn" "--reverse" "--index" "-") ("apply" "-p1" "--whitespace=nowarn" "--reverse" "--cached" "-")
                      ("apply" "-p1" "--whitespace=nowarn" "--reverse" "--reject" "-"))
                    (map git:command-arguments (list-tail (git:commands lists) before))))))
