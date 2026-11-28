(import (tuna) (test) (eval-test caught-reports) (test-runner) (test-user) (options) (ask) (commands) (files attributes) (document) (buffers)
        (views) (layout) (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (kill-ring) (dired)
        (dired-test))

(define (lines) (dired-test:shown-lines))

(define (asked-and-said keys) (let ([said (dired-test:press-for-message! keys)]) (list (dired-test:questions) said)))

(dired-test:touch! "ops/a.txt" "a\n")
(dired-test:touch! "ops/b.txt" "b\n")
(dired-test:touch! "ops/c.txt" "c\n")
(dired-test:touch! "ops/full/inside.txt" "i\n")
(dired-test:folder! "ops/empty")

(define b (dired:visit (dired-test:home-path "ops")))

(layout:switch-to-buffer b)

(options:set! ask:yes-or-no-reader (dired-test:answer #t))

(test "D deletes the entry at point after asking with dired:deletion-confirmer, then reads the listing again"
  (dired-test:goto! "a.txt")
  (check-equal? '(("Delete a.txt? ") "Deleted 1 file") (asked-and-said "D"))
  (check-equal? '(#f ("  ." "  .." "  b.txt" "  c.txt" "  empty" "  full")) (list (dired-test:exists? "ops/a.txt") (lines))))

(define shown-while-asking #f)

(define (note-deletions question)
  (set! shown-while-asking
    (let ([d (buffers:find " *Deletions*")])
      (and d (pair? (views:showing d)))))
  ((dired-test:answer #t) question))

(test "several marked entries are named in *Deletions* while it asks, which goes when answered; a folder that holds files is asked about, as dired:recursive-deletes is top"
  (options:set! dired:deletion-confirmer note-deletions)
  (dired-test:goto! "b.txt")
  (test-user:press! "m m m m")
  (check-equal? '(("Delete * [4 files]? " "Recursively delete full? ") "Deleted 4 files") (asked-and-said "D"))
  (check-equal? '(#t #f ("  ." "  ..")) (list shown-while-asking (buffers:find " *Deletions*") (lines)))
  (options:unset! dired:deletion-confirmer))

(test "with dired:recursive-deletes never, a folder that holds files is refused; the other paths are still deleted, and the message names what failed"
  (dired-test:touch! "ops/keep/inside.txt" "i\n")
  (dired-test:touch! "ops/gone.txt" "g\n")
  (dired-test:press-until-read! "g")
  (options:set! dired:recursive-deletes (dired:recursion never))
  (check-equal? 2 (dired:mark-where! b (lambda (e) #t) #\*))
  (check-equal? '(("Delete * [2 files]? ") "1 of 2 files failed: Cannot delete keep: it holds files")
    (asked-and-said "D"))
  (check-equal? '("  ." "  .." "* keep") (lines))
  (options:unset! dired:recursive-deletes))

(test "with files:delete-by-moving-to-trash?, the questions say trash and the files go to the freedesktop.org trash, with their .trashinfo"
  (options:set! files:delete-by-moving-to-trash? #t)
  (check-equal? '(("Trash keep? " "Recursively trash keep? ") "Trashed 1 file") (asked-and-said "D"))
  (check-equal? '(("  ." "  ..") #t #t)
    (list (lines) (dired-test:exists? ".local/share/Trash/files/keep/inside.txt") (dired-test:exists? ".local/share/Trash/info/keep.trashinfo")))
  (options:unset! files:delete-by-moving-to-trash?))

(test "x deletes the entries flagged D, and says so when none are"
  (check-equal? "(No deletions requested)" (dired-test:press-for-message! "x")))

(test "declining the question deletes nothing, and says so, as Dired does"
  (dired-test:touch! "ops/no.txt" "n\n")
  (dired-test:press-until-read! "g")
  (dired-test:goto! "no.txt")
  (options:set! dired:deletion-confirmer (dired-test:answer #f))
  (check-equal? '(("Delete no.txt? ") "(No deletions performed)") (asked-and-said "D"))
  (check (dired-test:exists? "ops/no.txt"))
  (options:unset! dired:deletion-confirmer)
  (delete-file (dired-test:home-path "ops/no.txt")))

(test "x deletes the flagged entries after asking"
  (dired-test:touch! "ops/x.txt" "x\n")
  (dired-test:touch! "ops/y.txt" "y\n")
  (dired-test:press-until-read! "g")
  (dired-test:goto! "x.txt")
  (test-user:press! "d")
  (dired-test:press-for-message! "x")
  (check-equal? '(("Delete x.txt? ") ("  ." "  .." "  y.txt")) (list (dired-test:questions) (lines))))

(define y (files:visit (dired-test:home-path "ops/y.txt")))

(test "R renames the entry at point; a buffer visiting it follows, the entry keeps its mark, and point follows the file"
  (dired-test:goto! "y.txt")
  (test-user:press! "m")
  (dired-test:goto! "y.txt")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/z.txt"))
  (check-equal? '(("Rename y.txt to: ") "Moved 1 file") (asked-and-said "R"))
  (check-equal? (list '("  ." "  .." "* z.txt") "z.txt" (dired-test:home-path "ops/z.txt") "z.txt")
    (list (lines) (buffers:name y) (files:path y) (dired-test:point-name))))

(test "a file renamed or copied to itself fails, and the message says so in a sentence"
  (test-user:press! "U")
  (check-equal? '(("Rename z.txt to: ") "1 of 1 file failed: Cannot move z.txt to itself") (asked-and-said "R"))
  (check-equal? '(("Copy z.txt to: ") "1 of 1 file failed: Cannot copy z.txt to itself") (asked-and-said "C"))
  (test-user:press! "C-/"))

(define into #f)

(test "several paths move into a folder, which that folder's listing shows with their marks; an existing target is asked about, and one declined is named apart"
  (dired-test:touch! "ops/w.txt" "w\n")
  (dired-test:folder! "ops/into")
  (dired-test:touch! "ops/into/w.txt" "old\n")
  (set! into (dired:visit (dired-test:home-path "ops/into")))
  (dired-test:press-until-read! "g")
  (dired-test:goto! "w.txt")
  (test-user:press! "m")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/into/"))
  (options:set! ask:y-or-n-reader (dired-test:answer #f))
  (check-equal? '(("Move * [2 files] to: " "Overwrite ~/ops/into/w.txt? ") "Moved 1 file; declined w.txt") (asked-and-said "R"))
  (test-runner:wait-until (lambda () (equal? '("  ." "  .." "  w.txt" "* z.txt") (dired-test:lines into))))
  (check-equal? '("  ." "  .." "  into" "* w.txt") (lines)))

(define (modified path) (file-attributes-modified (read-file-attributes (dired-test:home-path path))))

(test "C copies, keeping the modification time, and marks the copy C"
  (dired-test:goto! "w.txt")
  (test-user:press! "u")
  (dired-test:goto! "w.txt")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/v.txt"))
  (check-equal? '(("Copy w.txt to: ") "Copied 1 file") (asked-and-said "C"))
  (check-equal? '("  ." "  .." "  into" "C v.txt" "  w.txt") (lines))
  (check (= (modified "ops/w.txt") (modified "ops/v.txt"))))

(test "a folder is copied with everything in it after asking, as dired:recursive-copies is top"
  (dired-test:goto! "into")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/into2"))
  (dired-test:press-for-message! "C")
  (check-equal? '(("Copy into to: " "Recursive copies of into? ") #t ("  ." "  .." "  into" "C into2" "C v.txt" "  w.txt"))
    (list (dired-test:questions) (dired-test:exists? "ops/into2/z.txt") (lines))))

(test "+ makes a folder and the missing folders above it, with point on the first made"
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/made/deeper"))
  (dired-test:press-until! "+" (lambda () (dired-test:exists? "ops/made/deeper")))
  (test-runner:wait-until (lambda () (equal? "made" (dired-test:point-name))))
  (check-equal? '("Create folder: ") (dired-test:questions)))

(test "w copies the names to the kill ring, and with 0 the whole paths"
  (dired-test:goto! "w.txt")
  (test-user:press! "w")
  (check-equal? '("w.txt" "w.txt") (list (kill-ring:text (kill-ring:current)) (echo-area:current-message)))
  (test-user:press! "0 w")
  (check-equal? (dired-test:home-path "ops/w.txt") (kill-ring:text (kill-ring:current))))

(define started #f)

(test "with dired:other-listing-target?, R and C start in the folder of the first listing in the views after the selected one"
  (options:set! ask:file-name-reader (lambda (q folder) (set! started folder) "~/ops/w2.txt"))
  (options:set! dired:other-listing-target? #t)
  (layout-split:split-right #f)
  (layout:switch-to-buffer into)
  (layout:other-view 1)
  (dired-test:goto! "w.txt")
  (dired-test:press-for-message! "C")
  (check-equal? (dired-test:home-path "ops/into/") started)
  (dired-test:touch! "ops/third/t.txt" "t\n")
  (layout-split:split-right #f)
  (layout:switch-to-buffer (dired:visit (dired-test:home-path "ops/third")))
  (check-equal? (map dired-test:home-path '("ops/into/" "ops/third/" "ops/"))
    (filter values (map (lambda (v) (dired:folder (views:buffer v))) (layout:views))))
  (for-each (lambda (folder) (layout:select! (find (lambda (v) (equal? (dired:folder (views:buffer v)) folder)) (layout:views))))
            (map dired-test:home-path '("ops/" "ops/into/" "ops/third/")))
  (dired-test:goto! "t.txt")
  (dired-test:press-for-message! "C")
  (check-equal? (dired-test:home-path "ops/") started)
  (options:unset! dired:other-listing-target?))

(test "R onto a file another buffer visits is refused before Overwrite is asked, and nothing moves"
  (dired-test:touch! "ops/third/u.txt" "u\n")
  (let ([u (files:visit (dired-test:home-path "ops/third/u.txt"))])
    (dired-test:press-until-read! "g")
    (dired-test:questions)
    (dired-test:goto! "t.txt")
    (options:set! ask:file-name-reader (dired-test:answer "~/ops/third/u.txt"))
    (options:set! ask:y-or-n-reader (dired-test:answer #t))
    (check-equal? '(("Rename t.txt to: ") "1 of 1 file failed: Cannot move t.txt: another buffer visits u.txt") (asked-and-said "R"))
    (check-equal? (list '("." ".." "t.txt" "u.txt") (dired-test:home-path "ops/third/u.txt"))
      (list (map dired-test:entry-name (dired-test:entries (views:buffer (dired-test:view)))) (files:path u)))))

(test "a folder the user declines to delete or copy recursively is named apart from those done"
  (dired-test:touch! "ops/third/full/inside.txt" "i\n")
  (dired-test:press-until-read! "g")
  (dired-test:goto! "full")
  (options:set! dired:deletion-confirmer (dired-test:answer #t))
  (options:set! ask:yes-or-no-reader (dired-test:answer #f))
  (check-equal? '(("Delete full? " "Recursively delete full? ") "Deleted 0 files; declined full") (asked-and-said "D"))
  (check (dired-test:exists? "ops/third/full/inside.txt"))
  (options:unset! dired:deletion-confirmer)
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/copy"))
  (check-equal? '(("Copy full to: " "Recursive copies of full? ") "Copied 0 files; declined full") (asked-and-said "C"))
  (check (not (dired-test:exists? "ops/copy"))))

(test "C of a link onto a folder fails after Overwrite, and the folder keeps its files"
  (dired-test:symlink! "elsewhere" "ops/third/l")
  (dired-test:touch! "ops/dst/l/precious.txt" "keep\n")
  (dired-test:press-until-read! "g")
  (dired-test:goto! "l")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/dst/"))
  (options:set! ask:y-or-n-reader (dired-test:answer #t))
  (let ([result (asked-and-said "C")])
    (check-equal? '("Copy l to: " "Overwrite ~/ops/dst/l? ") (car result))
    (check (dired-test:starts-with? "1 of 1 file failed: Cannot copy l: " (cadr result))))
  (check (dired-test:exists? "ops/dst/l/precious.txt")))

(test "C-u D, R and C act on the entry at point even with others marked; C-u w names the marked entries"
  (dired-test:touch! "ops/pick/a.txt" "a\n")
  (dired-test:touch! "ops/pick/b.txt" "b\n")
  (dired-test:touch! "ops/pick/c.txt" "c\n")
  (layout:switch-to-buffer (dired:visit (dired-test:home-path "ops/pick")))
  (dired-test:goto! "b.txt")
  (test-user:press! "m")
  (dired-test:goto! "a.txt")
  (options:set! dired:deletion-confirmer (dired-test:answer #t))
  (check-equal? '(("Delete a.txt? ") "Deleted 1 file") (asked-and-said "C-u D"))
  (check-equal? '("  ." "  .." "* b.txt" "  c.txt") (lines))
  (options:unset! dired:deletion-confirmer)
  (dired-test:goto! "c.txt")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/pick/d.txt"))
  (check-equal? '(("Rename c.txt to: ") "Moved 1 file") (asked-and-said "C-u R"))
  (check-equal? '("  ." "  .." "* b.txt" "  d.txt") (lines))
  (dired-test:goto! "d.txt")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/pick/e.txt"))
  (check-equal? '(("Copy d.txt to: ") "Copied 1 file") (asked-and-said "C-u C"))
  (check-equal? '("  ." "  .." "* b.txt" "  d.txt" "C e.txt") (lines))
  (dired-test:goto! "d.txt")
  (test-user:press! "C-u w")
  (check-equal? "b.txt" (echo-area:current-message)))

(test "dired:operation-paths takes a prefix argument of its own, so a command whose C-u means something else asks for the marked entries"
  (check-equal? '("d.txt")
    (parameterize ([commands:prefix-argument '-]) (map path-last (dired:operation-paths (dired-test:view)))))
  (check-equal? '("b.txt")
    (parameterize ([commands:prefix-argument '(4)]) (map path-last (dired:operation-paths (dired-test:view) #f))))
  (check-equal? '("d.txt") (map path-last (dired:operation-paths (dired-test:view) '(4)))))

(test "D, C and R on . or .. say they cannot operate on them, and ask nothing"
  (dired-test:touch! "ops/dots/a.txt" "a\n")
  (layout:switch-to-buffer (dired:visit (dired-test:home-path "ops/dots")))
  (dired-test:questions)
  (dired-test:goto! ".")
  (check-equal? '("Cannot operate on . or .." 1) (dired-test:refused "D"))
  (check-equal? '("Cannot operate on . or .." 1) (dired-test:refused "C"))
  (dired-test:goto! "..")
  (check-equal? '("Cannot operate on . or .." 1) (dired-test:refused "R"))
  (check-equal? '(() ("  ." "  .." "  a.txt")) (list (dired-test:questions) (lines))))

(test "the question names how several files were chosen: D for the flagged, * for the marked, and a count as the next N"
  (for-each (lambda (name) (dired-test:touch! (string-append "ops/dots/" name) "x\n")) '("b.txt" "c.txt" "d.txt"))
  (dired-test:press-until-read! "g")
  (options:set! dired:deletion-confirmer (dired-test:answer #f))
  (dired-test:goto! "a.txt")
  (test-user:press! "d d")
  (dired-test:press-for-message! "x")
  (test-user:press! "U")
  (dired-test:goto! "a.txt")
  (test-user:press! "m m")
  (dired-test:press-for-message! "D")
  (test-user:press! "U")
  (dired-test:goto! "c.txt")
  (dired-test:press-for-message! "2 D")
  (dired-test:goto! "d.txt")
  (dired-test:press-for-message! "- 2 D")
  (check-equal? '("Delete D [2 files]? " "Delete * [2 files]? " "Delete [next 2 files]? " "Delete [next -2 files]? ")
    (dired-test:questions))
  (options:unset! dired:deletion-confirmer))

(define names-while-asking #f)

(define (note-marked-files reply)
  (lambda (question folder)
    (set! names-while-asking
      (let ([names (buffers:find " *Marked Files*")])
        (and names (pair? (views:showing names)) (document:text (buffers:document names)))))
    ((dired-test:answer reply) question folder)))

(test "R and C of several files show their names while they ask for the target, and take them away when answered"
  (dired-test:folder! "ops/dots/into")
  (dired-test:press-until-read! "g")
  (dired-test:goto! "a.txt")
  (options:set! ask:file-name-reader (note-marked-files "~/ops/dots/into/"))
  (check-equal? '(("Copy [next 2 files] to: ") "Copied 2 files") (asked-and-said "2 C"))
  (check-equal? '("a.txt\nb.txt\n" #f) (list names-while-asking (buffers:find " *Marked Files*")))
  (test-user:press! "U")
  (dired-test:goto! "c.txt")
  (test-user:press! "m m")
  (check-equal? '(("Move * [2 files] to: ") "Moved 2 files") (asked-and-said "R"))
  (check-equal? '("c.txt\nd.txt\n" #f) (list names-while-asking (buffers:find " *Marked Files*")))
  (check-equal? '("  ." "  .." "  a.txt" "  b.txt" "  into") (lines)))

(test "+ of a name that exists says it cannot create the folder, naming it"
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/dots/into"))
  (check-equal? '("Cannot create folder ~/ops/dots/into: it exists" 1) (dired-test:refused "+"))
  (dired-test:questions))

(test "C of a folder into a folder inside it fails, naming the target from the listing's folder"
  (dired-test:folder! "ops/dots/into/inner")
  (dired-test:goto! "into")
  (options:set! ask:yes-or-no-reader (dired-test:answer #t))
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/dots/into/inner/copy"))
  (check-equal? '(("Copy into to: " "Recursive copies of into? ") "1 of 1 file failed: Cannot copy into into its own folder into/inner/copy")
    (asked-and-said "C"))
  (check (not (dired-test:exists? "ops/dots/into/inner/copy"))))

(test "R or C of several files into a path that is not a folder says so, naming it"
  (dired-test:goto! "a.txt")
  (options:set! ask:file-name-reader (dired-test:answer "~/ops/dots/b.txt"))
  (check-equal? '("~/ops/dots/b.txt is not a folder" 1) (dired-test:refused "2 C"))
  (check-equal? '("Copy [next 2 files] to: ") (dired-test:questions)))
