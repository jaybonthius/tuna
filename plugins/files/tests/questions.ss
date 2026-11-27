(import (tuna) (test) (hooks) (options) (ask) (commands) (keys) (tables) (buffers) (files) (files-test))

(options:set! files:require-final-newline #t)

;; The texts of the overwrite, write-protection and kill questions, and a
;; refusal's message, are left out: they are to change to name the file
;; and to read as sentences.
(define (canceled-by who) (lambda (c) (and (files:canceled-condition? c) (eq? who (condition-who c)))))

(define (raised-by who) (lambda (c) (and (error? c) (eq? who (condition-who c)))))

;; A command run reports what it raises.
(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (check-reported who? thunk)
  (let ([reports (reports-during thunk)])
    (check-equal? '(#t) (map who? reports))))

(define (readers! file-name y-or-n)
  (options:set! ask:file-name-reader (files-test:answer file-name))
  (options:set! ask:y-or-n-reader (files-test:answer y-or-n)))

(define draft (buffers:make "*draft*" "draft"))

(test "run as a command, write-file asks before it replaces a file, and C-u skips the question; called from code, it never asks"
  (files-test:write-text! "~/taken.txt" "taken\n")
  (readers! "~/taken.txt" #f)
  (check-reported (canceled-by 'files:write-file) (lambda () (buffers:with-buffer draft (commands:run files:write-file))))
  (let ([asked (files-test:questions)])
    (check-equal? '("Write file: " 2) (list (car asked) (length asked))))
  (check-equal? '(#f "taken\n") (list (files:path draft) (files-test:read-text "~/taken.txt")))
  (parameterize ([commands:prefix-argument '(4)]) (buffers:with-buffer draft (commands:run files:write-file)))
  (check-equal? (list '("Write file: ") (files-test:expand "~/taken.txt") "draft\n")
    (list (files-test:questions) (files:path draft) (files-test:read-text "~/taken.txt")))
  (files:write-file "~/taken.txt" draft)
  (check-equal? '() (files-test:questions)))

(test "saving a write-protected file asks yes or no first, and a save keeps the file's mode"
  (files-test:set-mode! "~/taken.txt" #o444)
  (buffers:replace! draft 1 1 "a ")
  (options:set! ask:yes-or-no-reader (files-test:answer #f))
  (check-raises (canceled-by 'files:save-buffer) (files:save-buffer draft))
  (check-equal? '(1 "draft\n" #t) (list (length (files-test:questions)) (files-test:read-text "~/taken.txt") (buffers:modified? draft)))
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (files:save-buffer draft)
  (check-equal? '(1 "a draft\n" "444")
    (list (length (files-test:questions)) (files-test:read-text "~/taken.txt") (number->string (files-test:mode "~/taken.txt") 8)))
  (buffers:replace! draft 1 1 "b ")
  (files:write-file "~/taken.txt" draft)
  (check-equal? '(() "b a draft\n") (list (files-test:questions) (files-test:read-text "~/taken.txt")))
  (buffers:replace! draft 1 1 "c ")
  (options:set! ask:y-or-n-reader (files-test:answer #t))
  (buffers:with-buffer draft (commands:run files:write-file))
  (let ([asked (files-test:questions)])
    (check-equal? '("Write file: " 3) (list (car asked) (length asked))))
  (check-equal? "c b a draft\n" (files-test:read-text "~/taken.txt")))

(test "a buffer written to a file named as the buffer keeps its name"
  (let ([named (buffers:make "named.txt" "named")])
    (files-test:folder! "~/named")
    (files:write-file "~/named/named.txt" named)
    (check-equal? (list "named.txt" (files-test:expand "~/named/named.txt")) (list (buffers:name named) (files:path named)))))

(define one (files:visit "~/one.txt"))
(define two (files:visit "~/two.txt"))

(test "C-x s asks y or n for each modified file buffer, in the order they were visited, and saves those answered y"
  (check-equal? 'files:save-some-buffers (commands:command-name (tables:ref keys:global "C-x s")))
  (buffers:replace! one 1 1 "1")
  (buffers:replace! two 1 1 "2")
  (options:set! ask:y-or-n-reader (files-test:replies #f #t))
  (commands:run files:save-some-buffers)
  (check-equal? '(("Save file ~/one.txt? " "Save file ~/two.txt? ") #f "2\n" #t)
    (list (files-test:questions) (files-test:exists? "~/one.txt") (files-test:read-text "~/two.txt") (buffers:modified? one))))

(define deep (files:visit "~/new/folder/deep.txt"))

(test "saving into a folder that does not exist asks whether to make it"
  (buffers:replace! deep 1 1 "deep")
  (options:set! ask:y-or-n-reader (files-test:answer #f))
  (check-raises (canceled-by 'files:save-buffer) (files:save-buffer deep))
  (check-equal? '(("Folder ~/new/folder does not exist; create? ") #f #t)
    (list (files-test:questions) (files-test:exists? "~/new") (buffers:modified? deep)))
  (options:set! ask:y-or-n-reader (files-test:answer #t))
  (files:save-buffer deep)
  (check-equal? '(("Folder ~/new/folder does not exist; create? ") "deep\n")
    (list (files-test:questions) (files-test:read-text "~/new/folder/deep.txt"))))

(test "called from code, write-file makes no folder"
  (check-raises (raised-by 'files:write-file) (files:write-file "~/elsewhere/w.txt" (buffers:make "*w*" "w")))
  (check-equal? '() (files-test:questions)))

(define jot (buffers:make "*jot*" ""))

(test "saving a modified buffer that visits no file asks for a file, then asks as write-file does as a command; an unmodified one asks nothing"
  (files-test:write-text! "~/kept.txt" "kept\n")
  (readers! "~/kept.txt" #f)
  (files:save-buffer jot)
  (check-equal? '() (files-test:questions))
  (buffers:replace! jot 1 1 "jot")
  (check-raises (canceled-by 'files:save-buffer) (files:save-buffer jot))
  (let ([asked (files-test:questions)])
    (check-equal? '("File to save in: " 2 #f) (list (car asked) (length asked) (files:path jot))))
  (options:set! ask:file-name-reader (files-test:answer "~/jot.txt"))
  (files:save-buffer jot)
  (check-equal? (list '("File to save in: ") (files-test:expand "~/jot.txt") "jot.txt" "jot\n" #f)
    (list (files-test:questions) (files:path jot) (buffers:name jot) (files-test:read-text "~/jot.txt") (buffers:modified? jot))))

(define loose (buffers:make "*loose*" ""))

(test "a folder, or a file another buffer visits, is refused as the file to save in, before the buffer is renamed or a folder made"
  (buffers:replace! loose 1 1 "loose")
  (options:set! ask:file-name-reader (files-test:answer "~/"))
  (check-raises (raised-by 'files:save-buffer) (files:save-buffer loose))
  (check-equal? '(("File to save in: ") "*loose*" #f) (list (files-test:questions) (buffers:name loose) (files:path loose)))
  (files:visit "~/far/away.txt")
  (options:set! ask:file-name-reader (files-test:answer "~/far/away.txt"))
  (check-reported (raised-by 'files:write-file) (lambda () (buffers:with-buffer loose (commands:run files:write-file))))
  (check-equal? '(("Write file: ") "*loose*" #f) (list (files-test:questions) (buffers:name loose) (files-test:exists? "~/far"))))

(test "a no raises a files:&canceled condition, an error"
  (readers! "~/kept.txt" #f)
  (check-raises (lambda (c) (and (files:canceled-condition? c) (error? c) (eq? 'files:save-buffer (condition-who c))))
    (files:save-buffer loose))
  (check-equal? 2 (length (files-test:questions))))

(test "given a folder, write-file writes the file in it named as the buffer's file, or as the buffer when it visits none; a name ending in / is a folder even before it exists"
  (let ([moved (files:visit "~/moved.txt")] [scrap (buffers:make "*scrap*" "scrap")])
    (buffers:replace! moved 1 1 "moved")
    (files:write-file "~/new/" moved)
    (check-equal? (list (files-test:expand "~/new/moved.txt") "moved.txt" "moved\n")
      (list (files:path moved) (buffers:name moved) (files-test:read-text "~/new/moved.txt")))
    (files:write-file "~/new/folder" moved)
    (check-equal? (list (files-test:expand "~/new/folder/moved.txt") "moved\n")
      (list (files:path moved) (files-test:read-text "~/new/folder/moved.txt")))
    (readers! "~/fresh/" #t)
    (buffers:with-buffer scrap (commands:run files:write-file))
    (check-equal? (list '("Write file: " "Folder ~/fresh does not exist; create? ") (files-test:expand "~/fresh/*scrap*") "*scrap*" "scrap\n")
      (list (files-test:questions) (files:path scrap) (buffers:name scrap) (files-test:read-text "~/fresh/*scrap*")))
    (options:set! ask:y-or-n-reader (files-test:answer #f))
    (check-reported (canceled-by 'files:write-file) (lambda () (buffers:with-buffer scrap (commands:run files:write-file))))
    (let ([asked (files-test:questions)])
      (check-equal? '("Write file: " 2) (list (car asked) (length asked))))
    (files-test:folder! "~/box")
    (files-test:folder! "~/box/*scrap*")
    (options:set! ask:file-name-reader (files-test:answer "~/box/"))
    (check-reported (raised-by 'files:write-file) (lambda () (buffers:with-buffer scrap (commands:run files:write-file))))
    (check-equal? (list '("Write file: ") (files-test:expand "~/fresh/*scrap*")) (list (files-test:questions) (files:path scrap)))
    (check-raises (raised-by 'files:write-file) (files:write-file "~/box/" scrap))
    (check-equal? (list (files-test:expand "~/fresh/*scrap*") "*scrap*") (list (files:path scrap) (buffers:name scrap)))))

(commands:define-command (kill [buffer (buffers:current)]) "Kills BUFFER." (buffers:kill! buffer))

(define (keep-all buffer) #t)

(test "a command that kills a modified buffer asks first, unless an entry of files:unsaved-kept keeps its edits; code outside a command, an unmodified buffer and an internal one are not asked about"
  (let ([unsaved (buffers:make "*unsaved*" "")] [internal (buffers:make " *internal*" "")] [note (buffers:make "*note*" "")]
        [later (buffers:make "*later*" "")])
    (buffers:replace! unsaved 1 1 "text")
    (options:set! ask:y-or-n-reader (files-test:answer #f))
    (check-equal? '(#f 1 #t) (list (commands:run kill unsaved) (length (files-test:questions)) (buffers:live? unsaved)))
    (options:set! ask:y-or-n-reader (files-test:answer #t))
    (check-equal? '(#t 1 #f) (list (commands:run kill unsaved) (length (files-test:questions)) (buffers:live? unsaved)))
    (buffers:replace! internal 1 1 "text")
    (options:set! ask:y-or-n-reader (files-test:answer #f))
    (check-equal? '(#f 1 #t) (list (commands:run kill one) (length (files-test:questions)) (buffers:live? one)))
    (hooks:add! files:unsaved-kept keep-all)
    (buffers:replace! note 1 1 "text")
    (check-equal? '(#t () #f) (list (commands:run kill note) (files-test:questions) (buffers:live? note)))
    (check-equal? '(#t #t #t) (map (lambda (b) (commands:run kill b)) (list one (buffers:make "*clean*" "") internal)))
    (hooks:remove! files:unsaved-kept keep-all)
    (buffers:replace! later 1 1 "text")
    (check (buffers:kill! later))
    (check-equal? '() (files-test:questions))))

(test "files:directory is the folder of a buffer's file, else the home folder; without a buffer it is the current buffer's"
  (check-equal? (map files-test:expand '("~/new/folder/" "~/" "~/"))
    (map files:directory (list deep jot (buffers:make "*none*" ""))))
  (check-equal? (files-test:expand "~/new/folder/") (buffers:with-buffer deep (files:directory))))
