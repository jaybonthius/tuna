(import (tuna) (test) (hooks) (options) (ask) (commands) (plain-data) (files attributes) (buffers) (files) (files-test))

(options:set! files:require-final-newline #t)

(define (raised thunk)
  (guard (c [(error? c) (list (condition-who c) (condition-message c))])
    (thunk)))

(define (raised-by who) (lambda (c) (and (error? c) (eq? who (condition-who c)))))

(define renames '())

(define (note-rename from to) (set! renames (cons (list from to) renames)))

(hooks:add! files:after-rename note-rename)

(define one #f)

(test "files:rename-file renames on a job; each buffer visiting the file, or a file under a renamed folder, follows, renamed and still modified; then files:after-rename runs"
  (files-test:folder! "~/d")
  (files-test:write-text! "~/d/one.txt" "one\n")
  (files-test:write-text! "~/d/two.txt" "two\n")
  (set! one (files:visit "~/d/one.txt"))
  (buffers:replace! one 1 1 "1 ")
  (files:rename-file "~/d/one.txt" "~/d/uno.txt")
  (check-equal? (list "uno.txt" (files-test:expand "~/d/uno.txt") #t '("two.txt" "uno.txt")
                      (list (list (files-test:expand "~/d/one.txt") (files-test:expand "~/d/uno.txt"))))
    (list (buffers:name one) (files:path one) (buffers:modified? one) (files-test:folder-files "~/d") renames))
  (files:rename-file "~/d" "~/e")
  (check-equal? (list (files-test:expand "~/e/uno.txt") #f (list (files-test:expand "~/d") (files-test:expand "~/e")))
    (list (files:path one) (files-test:exists? "~/d") (car renames))))

(test "a target that exists is replaced only with no-fail, and a folder never goes inside itself"
  (check-equal? '(files:rename-file "file exists") (raised (lambda () (files:rename-file "~/e/uno.txt" "~/e/two.txt"))))
  (files:rename-file "~/e/uno.txt" "~/e/two.txt" (file-options no-fail))
  (check-equal? '(("two.txt") "one\n") (list (files-test:folder-files "~/e") (files-test:read-text "~/e/two.txt")))
  (check-equal? '(files:rename-file "cannot put a folder inside itself") (raised (lambda () (files:rename-file "~/e" "~/e/inner")))))

(test "a failure's message names a path under the home folder with ~, and its filename stays whole, for code"
  (check-equal? (list (files-test:expand "~/none") "failed for ~/none: no such file or directory")
    (guard (c [(i/o-filename-error? c) (list (i/o-error-filename c) (condition-message c))])
      (files:rename-file "~/none" "~/other"))))

(test "a rename refuses a target, or a file under it, that a buffer it does not move visits, before it touches the disk; a file renamed or copied to itself is refused as the same file"
  (files-test:folder! "~/r")
  (files-test:write-text! "~/r/a.txt" "a\n")
  (files-test:write-text! "~/r/b.txt" "b\n")
  (let ([a (files:visit "~/r/a.txt")] [b (files:visit "~/r/b.txt")] [last-rename (car renames)])
    (check-raises (raised-by 'files:rename-file) (files:rename-file "~/r/a.txt" "~/r/b.txt" (file-options no-fail)))
    (check-equal? (list '("a.txt" "b.txt") (map files-test:expand '("~/r/a.txt" "~/r/b.txt")) '("a.txt" "b.txt") last-rename)
      (list (map buffers:name (list a b)) (map files:path (list a b)) (files-test:folder-files "~/r") (car renames)))
    (files-test:folder! "~/s")
    (let ([new (files:visit "~/s/new.txt")])
      (check-raises (raised-by 'files:rename-file) (files:rename-file "~/r" "~/s" (file-options no-fail)))
      (buffers:kill! new))
    (files:rename-file "~/r" "~/s" (file-options no-fail))
    (check-equal? (list (map files-test:expand '("~/s/a.txt" "~/s/b.txt")) #f) (list (map files:path (list a b)) (files-test:exists? "~/r")))
    (check-equal? '((files:rename-file "the same file") (files:copy-file "the same file"))
      (list (raised (lambda () (files:rename-file "~/s/a.txt" "~/s/a.txt"))) (raised (lambda () (files:copy-file "~/s" "~/s")))))
    (buffers:kill! a)
    (buffers:kill! b)))

(define (refusal thunk)
  (guard (c [(error? c)
             (list (map (lambda (refused?) (refused? c))
                        (list files:same-file-condition? files:inside-itself-condition? files:visited-elsewhere-condition?))
                   (i/o-error-filename c))])
    (thunk)))

(test "a refusal its caller words is a condition of its own, naming the path it refuses: the same file, a folder put inside itself, a file another buffer visits"
  (files-test:folder! "~/k")
  (files-test:write-text! "~/k/a.txt" "a\n")
  (files-test:write-text! "~/k/b.txt" "b\n")
  (let ([b (files:visit "~/k/b.txt")])
    (check-equal? (list (list '(#t #f #f) (files-test:expand "~/k/a.txt"))
                        (list '(#f #t #f) (files-test:expand "~/k/in"))
                        (list '(#f #f #t) (files-test:expand "~/k/b.txt")))
      (list (refusal (lambda () (files:copy-file "~/k/a.txt" "~/k/a.txt")))
            (refusal (lambda () (files:copy-file "~/k" "~/k/in")))
            (refusal (lambda () (files:rename-file "~/k/a.txt" "~/k/b.txt" (file-options no-fail))))))
    (buffers:kill! b)))

(test "a rename replaces only a file or an empty folder, also across file systems, where it copies; nothing moves when refused"
  (let* ([other (format "/dev/shm/tuna-files-~a" (get-process-id))] [in-other (lambda (name) (string-append other "/" name))])
    (files:make-folder (in-other "full"))
    (files:make-folder (in-other "empty"))
    (files-test:write-text! (in-other "full/keep.txt") "keep\n")
    (files-test:folder! "~/full")
    (files-test:write-text! "~/full/keep.txt" "keep\n")
    (let ([a (files:visit "~/s/a.txt")] [b (files:visit "~/s/b.txt")])
      (check-equal? '((files:rename-file "failed for ~/s: directory not empty") (files:rename-file "failed for ~/s: directory not empty")
                      (files:rename-file "failed for ~/s/a.txt: is a directory") (files:rename-file "failed for ~/s: not a directory"))
        (list (raised (lambda () (files:rename-file "~/s" "~/full" (file-options no-fail))))
              (raised (lambda () (files:rename-file "~/s" (in-other "full") (file-options no-fail))))
              (raised (lambda () (files:rename-file "~/s/a.txt" (in-other "empty") (file-options no-fail))))
              (raised (lambda () (files:rename-file "~/s" (in-other "full/keep.txt") (file-options no-fail))))))
      (check-equal? '(("a.txt" "b.txt") ("keep.txt") ("keep.txt"))
        (list (files-test:folder-files "~/s") (files-test:folder-files (in-other "full")) (files-test:folder-files "~/full")))
      (files:rename-file "~/s" (in-other "empty") (file-options no-fail))
      (check-equal? (list (map in-other '("empty/a.txt" "empty/b.txt")) '("a.txt" "b.txt") #f)
        (list (map files:path (list a b)) (files-test:folder-files (in-other "empty")) (files-test:exists? "~/s")))
      (buffers:kill! a)
      (buffers:kill! b))
    (files:delete-file other)))

(define (modified path) (file-attributes-modified (read-file-attributes (files-test:expand path))))

(test "files:copy-file copies a file keeping its mode and time, a folder with everything in it, and a symbolic link as a link"
  (files-test:set-mode! "~/e/two.txt" #o640)
  (files-test:symlink! "two.txt" "~/e/link")
  (files:copy-file "~/e" "~/f")
  (check-equal? '(("link" "two.txt") #t "640" #t)
    (list (files-test:folder-files "~/f") (files-test:symlink? "~/f/link") (number->string (files-test:mode "~/f/two.txt") 8)
          (= (modified "~/e/two.txt") (modified "~/f/two.txt"))))
  (check-equal? '(files:copy-file "failed for ~/f/two.txt: file exists") (raised (lambda () (files:copy-file "~/e/two.txt" "~/f/two.txt"))))
  (files-test:write-text! "~/e/three.txt" "3\n")
  (files:copy-file "~/e" "~/f" (file-options no-fail))
  (check-equal? '("link" "three.txt" "two.txt") (files-test:folder-files "~/f")))

(test "with no-fail a link replaces a file or a link, never a folder, whose files are kept"
  (files:copy-file "~/e/link" "~/f/three.txt" (file-options no-fail))
  (files:copy-file "~/e/link" "~/f/link" (file-options no-fail))
  (check-equal? '(#t #t) (list (files-test:symlink? "~/f/three.txt") (files-test:symlink? "~/f/link")))
  (files-test:folder! "~/src")
  (files-test:symlink! "elsewhere" "~/src/l")
  (files-test:folder! "~/dst")
  (files-test:folder! "~/dst/l")
  (files-test:write-text! "~/dst/l/precious.txt" "keep\n")
  (check-equal? '((files:copy-file "failed for ~/dst/l: is a directory") (files:copy-file "failed for ~/dst/l: is a directory"))
    (list (raised (lambda () (files:copy-file "~/src" "~/dst" (file-options no-fail))))
          (raised (lambda () (files:copy-file "~/src/l" "~/dst/l" (file-options no-fail))))))
  (check-equal? '(#f "keep\n") (list (files-test:symlink? "~/dst/l") (files-test:read-text "~/dst/l/precious.txt"))))

(test "files:delete-file deletes a link, not its target, and a folder with everything in it"
  (files:delete-file "~/f/link")
  (check-equal? '(("three.txt" "two.txt") #t) (list (files-test:folder-files "~/f") (files-test:exists? "~/e/two.txt")))
  (files:delete-file "~/f")
  (check (not (files-test:exists? "~/f")))
  (check-raises assertion-violation? (files:delete-file 'notes)))

(test "files:make-folder makes missing folders above too, and raises when the folder exists"
  (files:make-folder "~/g/h/i")
  (check (files-test:exists? "~/g/h/i"))
  (check-equal? '(files:make-folder "file exists") (raised (lambda () (files:make-folder "~/g/h")))))

(test "files:move-to-trash moves to the freedesktop.org trash with a .trashinfo naming the path; a second file of the name gets another"
  (files:move-to-trash "~/g/h")
  (files:make-folder "~/g/h")
  (files:move-to-trash "~/g/h")
  (check-equal? '(("h" "h.2") ("h.2.trashinfo" "h.trashinfo") "[Trash Info]\nPath=")
    (list (files-test:folder-files "~/.local/share/Trash/files") (files-test:folder-files "~/.local/share/Trash/info")
          (substring (files-test:read-text "~/.local/share/Trash/info/h.trashinfo") 0 18))))

(define listing (buffers:make "listing of e" ""))

(define visitors-asked '())

(define (decline folder) (set! visitors-asked (cons (path-last folder) visitors-asked)) #f)

(define (answer-listing folder) (set! visitors-asked (cons 'answered visitors-asked)) listing)

(test "files:visit of a folder asks files:folder-visitors by depth and takes the first buffer; with none answering it raises"
  (check-raises (raised-by 'files:read-document) (files:visit "~/e"))
  (hooks:add! files:folder-visitors answer-listing)
  (hooks:add! files:folder-visitors decline -10)
  (check-equal? (list #t '(answered "e")) (list (eq? listing (files:visit "~/e")) visitors-asked))
  (hooks:remove! files:folder-visitors answer-listing)
  (hooks:remove! files:folder-visitors decline))

(commands:define-command (kill [buffer (buffers:current)]) "Kills BUFFER." (buffers:kill! buffer))

(define (refuse question) (error 'ask "asked" question))

(test "in a buffer whose files:offer-save? is #f, killing it asks nothing and C-x C-s leaves it alone; files:write-file still writes it"
  (let ([marks (buffers:make "*marks*" "x")] [written (buffers:make "*written*" "w")])
    (buffers:replace! marks 1 1 "y")
    (buffers:with-buffer marks (options:set-local! files:offer-save? #f))
    (options:with ([ask:file-name-reader refuse] [ask:y-or-n-reader refuse])
      (buffers:with-buffer marks (commands:run files:save-buffer))
      (check-equal? '(#f #t) (list (files:path marks) (buffers:modified? marks)))
      (check (commands:run kill marks)))
    (buffers:with-buffer written (options:set-local! files:offer-save? #f))
    (files:write-file "~/written.txt" written)
    (check-equal? "w\n" (files-test:read-text "~/written.txt"))))

(test "(files attributes) reads a path without following a link, as plain data a job can send, through accessors that check it"
  (let ([a (read-file-attributes (files-test:expand "~/e/link"))])
    (check-equal? (list #t 'link "two.txt" 1 #t #t)
      (list (file-attributes? a) (file-attributes-type a) (file-attributes-target a) (file-attributes-links a)
            (eq? (file-attributes-type (read-file-attributes (files-test:expand "~/e"))) (file-type folder))
            (plain-data:plain-data? a))))
  (check-raises assertion-violation? (file-attributes-size (vector 'not)))
  (check (> (file-system-space (files-test:expand "~/")) 0)))

(test "a file's modification time is its seconds and the nanoseconds past them, as stat gives them"
  (let ([a (read-file-attributes (files-test:expand "~/e"))] [t (file-modification-time (files-test:expand "~/e"))])
    (check-equal? (list (time-second t) (time-nanosecond t))
      (list (file-attributes-modified a) (file-attributes-modified-nanoseconds a)))))
