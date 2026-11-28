(import (tuna) (test) (test-runner) (hooks) (options) (commands) (keys) (tables) (document) (buffers) (files)
        (only (files disk) failure failure-violation?) (files-test))

(options:set! files:require-final-newline #t)

(define (bytes-of b) (files-test:read-bytes (files:path b)))

(define (final-newline-off! b) (buffers:with-buffer b (options:set-local! files:require-final-newline #f)))

(define (raised-by who) (lambda (c) (and (who-condition? c) (eq? who (condition-who c)))))

(test "a byte order mark and CR LF line ends are kept, and the file saves byte for byte"
  (files-test:write-bytes! "~/bom.txt" #vu8(#xEF #xBB #xBF 97 13 10 98 13 10))
  (let ([bom (files:visit "~/bom.txt")])
    (check-equal? "a\nb\n" (files-test:text bom))
    (buffers:replace! bom 2 2 "!")
    (files:save-buffer bom)
    (check-equal? #vu8(239 187 191 97 33 13 10 98 13 10) (bytes-of bom))))

(test "a file of mixed line ends keeps its carriage returns as text"
  (files-test:write-bytes! "~/mixed.txt" (string->utf8 "a\r\nb\nc"))
  (let ([mixed (files:visit "~/mixed.txt")])
    (check-equal? "a\r\nb\nc" (files-test:text mixed))
    (final-newline-off! mixed)
    (buffers:replace! mixed 1 1 "0")
    (files:save-buffer mixed)
    (check-equal? "0a\r\nb\nc" (utf8->string (bytes-of mixed)))))

(test "a carriage return that ends no line stays text in a CR LF file"
  (files-test:write-bytes! "~/lone.txt" (string->utf8 "a\rb\r\n\r\r\n"))
  (let ([lone (files:visit "~/lone.txt")])
    (check-equal? "a\rb\n\r\n" (files-test:text lone))
    (buffers:replace! lone 1 1 "-")
    (files:save-buffer lone)
    (check-equal? "-a\rb\r\n\r\r\n" (utf8->string (bytes-of lone)))))

(test "bytes that are not UTF-8 are raw-byte atoms, written back as they were"
  (files-test:write-bytes! "~/latin.txt" #vu8(99 97 102 233 10 255 254 10))
  (let ([latin (files:visit "~/latin.txt")])
    (check-equal? '((buffers:text () "caf" #(document:raw-byte ((byte . 233))) "\n" #(document:raw-byte ((byte . 255)))
                     #(document:raw-byte ((byte . 254))) "\n"))
      (document:datums (buffers:document latin)))
    (buffers:replace! latin 1 1 "Le ")
    (files:save-buffer latin)
    (check-equal? #vu8(76 101 32 99 97 102 233 10 255 254 10) (bytes-of latin))))

(test "an empty file is an empty, unmodified buffer, and gains no line break"
  (files-test:write-bytes! "~/empty.txt" #vu8())
  (let ([empty (files:visit "~/empty.txt")])
    (check-equal? '("" #f (0 2166136261))
      (list (files-test:text empty) (buffers:modified? empty) (call-with-values (lambda () (files:fingerprint empty)) list)))
    (files:not-modified empty)
    (files:save-buffer empty)
    (check-equal? #vu8() (bytes-of empty))))

(test "a missing file gives an empty buffer that the first save creates, even in a missing folder; a folder is no file"
  (let ([fresh (files:visit "~/fresh.txt")])
    (check-equal? '("" #f #f) (list (files-test:text fresh) (buffers:modified? fresh) (files-test:exists? "~/fresh.txt")))
    (buffers:replace! fresh 1 1 "new")
    (files:save-buffer fresh)
    (check-equal? '("new\n" #f) (list (files-test:read-text "~/fresh.txt") (buffers:modified? fresh))))
  (check-equal? (files-test:expand "~/no/such/folder/x.txt") (files:path (files:visit "~/no/such/folder/x.txt")))
  (check-raises (raised-by 'files:read-document) (files:visit "~")))

(test "a save renames a new file over the old one, keeping its mode, and leaves no temporary file"
  (files-test:folder! "~/kept")
  (files-test:write-text! "~/kept/mode.txt" "mode\n")
  (files-test:set-mode! "~/kept/mode.txt" #o640)
  (let ([moded (files:visit "~/kept/mode.txt")])
    (buffers:replace! moded 1 1 "a ")
    (files:save-buffer moded)
    (check-equal? '("a mode\n" "640" ("mode.txt"))
      (list (files-test:read-text "~/kept/mode.txt") (number->string (files-test:mode "~/kept/mode.txt") 8) (files-test:folder-files "~/kept")))))

(test "paths resolve through symbolic links: two names, one buffer, and a link stays a link"
  (files-test:write-text! "~/kept/target.txt" "target\n")
  (files-test:symlink! "~/kept/target.txt" "~/kept/link.txt")
  (let ([linked (files:visit "~/kept/link.txt")])
    (check-equal? (list "target.txt" (files-test:expand "~/kept/target.txt") #t #t)
      (list (buffers:name linked) (files:path linked) (eq? linked (files:visit "~/kept/target.txt"))
            (eq? linked (files:buffer-visiting "~/kept/./link.txt"))))
    (buffers:replace! linked 1 1 "the ")
    (files:save-buffer linked)
    (check-equal? '(#t "the target\n") (list (files-test:symlink? "~/kept/link.txt") (files-test:read-text "~/kept/link.txt")))))

(test "a file with other hard links is written in place, so the links stay one file"
  (files-test:write-text! "~/kept/a.txt" "shared\n")
  (files-test:link! "~/kept/a.txt" "~/kept/b.txt")
  (let ([hard (files:visit "~/kept/a.txt")])
    (buffers:replace! hard 1 1 "still ")
    (files:save-buffer hard)
    (check-equal? '(2 "still shared\n") (list (files-test:link-count "~/kept/a.txt") (files-test:read-text "~/kept/b.txt")))))

(test "files of one name are named after their folders; killing one renames the other back; a buffer not a file's, or renamed by the user, keeps its name"
  (for-each files-test:folder! '("~/docs" "~/work" "~/x" "~/x/docs"))
  (for-each (lambda (p) (files-test:write-text! p "n\n")) '("~/docs/n.txt" "~/work/n.txt" "~/x/docs/n.txt"))
  (let* ([home (path-last (getenv "HOME"))] [docs (files:visit "~/docs/n.txt")])
    (check-equal? "n.txt" (buffers:name docs))
    (let ([work (files:visit "~/work/n.txt")])
      (check-equal? '("n.txt<docs>" "n.txt<work>") (map buffers:name (list docs work)))
      (let ([x-docs (files:visit "~/x/docs/n.txt")])
        (check-equal? (list (format "n.txt<~a/docs>" home) (format "n.txt<~a/work>" home) "n.txt<x/docs>")
          (map buffers:name (list docs work x-docs)))
        (buffers:kill! x-docs))
      (check-equal? '("n.txt<docs>" "n.txt<work>") (map buffers:name (list docs work)))
      (buffers:kill! work))
    (check-equal? "n.txt" (buffers:name docs))
    (buffers:rename! docs "my notes")
    (let ([work (files:visit "~/work/n.txt")])
      (check-equal? '("my notes" "n.txt") (map buffers:name (list docs work))))
    (let ([other-buffer (buffers:make "m.txt" "not a file")])
      (files-test:write-text! "~/work/m.txt" "m\n")
      (check-equal? "m.txt<work>" (buffers:name (files:visit "~/work/m.txt")))
      (check-equal? #f (files:path other-buffer)))))

(test "a file's buffer whose name would start with a space gets a bar in front, as in Emacs"
  (files-test:write-text! "~/ space.txt" "s\n")
  (files-test:write-text! "~/work/ space.txt" "s\n")
  (check-equal? (list (format "| space.txt<~a>" (path-last (getenv "HOME"))) "| space.txt<work>")
    (map buffers:name (list (files:visit "~/ space.txt") (files:visit "~/work/ space.txt")))))

(define draft (buffers:make "*draft*" "(+ 1 2)"))

(test "write-file makes a buffer visit a file, renamed after it, and writes whatever the file holds"
  (files:write-file "~/work/sum.ss" draft)
  (check-equal? (list "sum.ss" (files-test:expand "~/work/sum.ss") "(+ 1 2)\n" #f)
    (list (buffers:name draft) (files:path draft) (files-test:read-text "~/work/sum.ss") (buffers:modified? draft)))
  (files-test:write-text! "~/work/sum.ss" "elsewhere\n")
  (buffers:replace! draft 1 1 ";")
  (files:write-file "~/work/sum.ss" draft)
  (check-equal? ";(+ 1 2)\n" (files-test:read-text "~/work/sum.ss"))
  (files:write-file "~/work/total.ss" draft)
  (check-equal? (list "total.ss" #f ";(+ 1 2)\n")
    (list (buffers:name draft) (files:buffer-visiting "~/work/sum.ss") (files-test:read-text "~/work/total.ss")))
  (check-raises (raised-by 'files:write-file) (files:write-file "~/work/n.txt" draft)))

(test "modified means changed since the last read, save or not-modified"
  (let ([m (files:visit "~/work/m.txt")] [other-buffer (buffers:make "other" "x")])
    (buffers:replace! m 1 1 "x")
    (buffers:replace! m 1 2 "")
    (check (buffers:modified? m))
    (files:not-modified m)
    (check (not (buffers:modified? m)))
    (files:save-buffer m)
    (check-equal? "m\n" (files-test:read-text "~/work/m.txt"))
    (buffers:replace! other-buffer 1 1 "y")
    (files:not-modified other-buffer)
    (check (not (buffers:modified? other-buffer)))))

(test "a file's fingerprint is its length and FNV-1a 32 hash, as Python computes it"
  (check-equal? '(2 3173953654) (call-with-values (lambda () (files:fingerprint (files:visit "~/work/m.txt"))) list))
  (check-equal? 3173953654 (files-test:fnv (files-test:read-bytes "~/work/m.txt"))))

(test "a revert replaces only the part that differs, as one edit, keeping anchors outside it; an unchanged file is not read in"
  (files-test:write-text! "~/rev.txt" "one\ntwo\nthree\n")
  (let* ([rev (files:visit "~/rev.txt")] [before (buffers:anchor rev 2)] [after (buffers:anchor rev 12)])
    (files-test:write-text! "~/rev.txt" "one\nTWO!\nthree\n")
    (buffers:replace! rev 1 1 "")
    (files:revert-from-file rev)
    (check-equal? '("one\nTWO!\nthree\n" 2 #f) (list (files-test:text rev) (buffers:version rev) (buffers:modified? rev)))
    (check-equal? '(5) (map buffers:edit-start (buffers:edits-since rev 1)))
    (check-equal? '(2 13) (list (buffers:anchor-position before) (buffers:anchor-position after)))
    (files:revert-from-file rev)
    (check-equal? 2 (buffers:version rev))
    (files-test:write-bytes! "~/rev.txt" #vu8(111 110 101 13 10 233 13 10))
    (files:revert-from-file rev)
    (check-equal? (list "one\n\xFFFC;\n" #vu8(111 110 101 13 10 233 13 10)) (list (files-test:text rev) (bytes-of rev)))
    (buffers:replace! rev 1 1 "#")
    (files:save-buffer rev)
    (check-equal? #vu8(35 111 110 101 13 10 233 13 10) (bytes-of rev))
    (files-test:write-bytes! "~/rev.txt" #vu8(35 111 110 101 13 10 234 13 10))
    (files:revert-from-file rev)
    (check-equal? '((buffers:text () "#one\n" #(document:raw-byte ((byte . 234))) "\n")) (document:datums (buffers:document rev)))
    (check-equal? '(6) (map buffers:edit-start (buffers:edits-since rev 4)))
    (delete-file (files-test:expand "~/rev.txt"))
    (check-raises (raised-by 'files:revert-from-file) (files:revert-from-file rev))))

(define calls '())

(define (note name) (lambda (b) (set! calls (cons (list name (buffers:name b) (eq? b (buffers:current))) calls))))

(define (refuse b) (error 'hooked "refused"))

(test "the hooks get the buffer, with it current, so local entries run too; an entry that raises is reported and the save goes on"
  (let ([after-visit (note 'after-visit)] [after-save (note 'after-save)] [after-revert (note 'after-revert)])
    (hooks:add! files:after-visit after-visit)
    (hooks:add! files:after-save after-save)
    (hooks:add! files:after-revert after-revert)
    (hooks:add! files:before-save refuse)
    (files-test:write-text! "~/hooks.txt" "h\n")
    (let ([hooked (files:visit "~/hooks.txt")])
      (check (eq? hooked (files:visit "~/hooks.txt")))
      (buffers:with-buffer hooked (hooks:add-local! files:before-save (note 'local-before-save)))
      (buffers:replace! hooked 1 1 "+")
      (check-equal? '(hooked) (map condition-who (test-runner:reports-during (lambda () (files:save-buffer hooked)))))
      (check-equal? "+h\n" (files-test:read-text "~/hooks.txt"))
      (hooks:remove! files:before-save refuse)
      (files:save-buffer hooked)
      (files:revert-from-file hooked))
    (for-each (lambda (h e) (hooks:remove! h e))
      (list files:after-visit files:after-save files:after-revert) (list after-visit after-save after-revert))
    (check-equal? '((after-visit "hooks.txt" #t) (local-before-save "hooks.txt" #t) (after-save "hooks.txt" #t)
                    (after-revert "hooks.txt" #t))
      (reverse calls))))

(test "the final line break files:require-final-newline adds is an edit, made only for text that lacks one"
  (files-test:write-text! "~/final.txt" "no break")
  (let ([final (files:visit "~/final.txt")])
    (buffers:replace! final 1 1 "a ")
    (files:save-buffer final)
    (check-equal? '(2 "a no break\n" #f) (list (buffers:version final) (files-test:text final) (buffers:modified? final)))
    (check-equal? (list '((buffers:text () "a no break\n")) 11 #t)
      (call-with-values (lambda () (files:read-document "~/final.txt"))
        (lambda (doc length hash) (list (document:datums doc) length (= hash (files-test:fnv (files-test:read-bytes "~/final.txt")))))))
    (buffers:kill! final)
    (check-equal? '(#f #f #f) (list (files:buffer-visiting "~/final.txt") (memq final (files:buffers)) (buffers:modified? final)))))

(test "arguments are checked"
  (check-raises (raised-by 'files:visit) (files:visit 'notes))
  (check-raises (raised-by 'files:save-buffer) (files:save-buffer 'notes))
  (check-raises (raised-by 'files:fingerprint) (files:fingerprint (buffers:make "no file" "")))
  (check-raises (raised-by 'files:path) (files:path "notes")))

(test "as Emacs's, a write says Wrote and the path, a visit of a missing file (New file), and a save of an unmodified buffer run as a command (No changes need to be saved)"
  (files-test:take-said!)
  (let ([said-file (files:visit "~/said.txt")])
    (check-equal? '("(New file)") (files-test:take-said!))
    (files:visit "~/said.txt")
    (files-test:write-text! "~/empty-said.txt" "")
    (files:visit "~/empty-said.txt")
    (check-equal? '() (files-test:take-said!))
    (buffers:replace! said-file 1 1 "x")
    (files:save-buffer said-file)
    (check-equal? '("Wrote ~/said.txt") (files-test:take-said!))
    (files:save-buffer said-file)
    (check-equal? '() (files-test:take-said!))
    (buffers:with-buffer said-file (commands:run files:save-buffer))
    (check-equal? '("(No changes need to be saved)") (files-test:take-said!))
    (files:write-file "~/said-2.txt" said-file)
    (check-equal? '("Wrote ~/said-2.txt") (files-test:take-said!))))

(test "a visit of a missing file in a folder that does not exist says so, as Emacs's visit does"
  (files-test:take-said!)
  (files:visit "~/missing-folder/inner/new.txt")
  (check-equal? '("(New file; folder ~/missing-folder/inner does not exist)") (files-test:take-said!)))

(test "C-x x g runs buffers:revert-buffer; files:revert-from-file says Reverted buffer when it runs as a command, and nothing when code calls it"
  (check-equal? 'buffers:revert-buffer (commands:command-name (tables:ref keys:global "C-x x g")))
  (let ([b (files:visit "~/said-2.txt")])
    (files-test:write-text! "~/said-2.txt" "changed\n")
    (files:revert-from-file b)
    (check-equal? '() (files-test:take-said!))
    (files-test:write-text! "~/said-2.txt" "changed again\n")
    (buffers:with-buffer b (commands:run buffers:revert-buffer))
    (check-equal? '("changed again\n" ("Reverted buffer")) (list (files-test:text b) (files-test:take-said!)))))

(test "a worker's failure from a defect is a violation, not a disk error"
  (check-equal? '(#t #f #f)
    (map (lambda (c) (failure-violation? (failure c))) (list (make-assertion-violation) (make-i/o-write-error) 'raised))))
