(import (tuna) (test) (caught-reports) (test-runner) (test-user) (hooks) (options) (ask) (commands) (keys) (modes)
        (files attributes) (document) (buffers) (views) (layout) (layout-split) (editing) (echo-area) (minibuffer)
        (completion) (files) (file-picker) (undo) (dired) (dired-test))

(dired-test:touch! "src/tuna/main.ss" "(main)\n")
(dired-test:touch! "src/tuna/main.o" "")
(dired-test:touch! "src/tuna/notes.txt~" "old\n")

(define b (dired:visit "~/src/tuna"))

(test "the page's examples: an entry's attributes, dired:mark-where! and dired:sort-by"
  (check (eq? b (dired:visit (dired-test:home-path "src/tuna"))))
  (layout:switch-to-buffer b)
  (dired-test:goto! "main.ss")
  (check-equal? 7 (views:with-view (dired-test:view)
                    (file-attributes-size (dired:entry-attributes (dired:entry-at (views:current))))))
  (check-equal? 1 (dired:mark-where! b (lambda (entry) (string=? (path-extension (dired:entry-path entry)) "o")) #\D))
  (dired-test:relisted! b (lambda () (views:with-view (dired-test:view) (dired:sort-by (buffers:current) (dired:sorting size)))))
  (check-equal? '("  ." "  .." "  main.ss" "  notes.txt~" "D main.o") (dired-test:lines b)))

(define (backup? entry)
  (let ([path (dired:entry-path entry)])
    (char=? (string-ref path (- (string-length path) 1)) #\~)))

(commands:define-command (flag-backups [buffer (buffers:current)])
  "Flags every backup file in the listing for deletion."
  (dired:mark-where! buffer backup? #\D))

(test "the page's command that flags every file whose name ends in ~"
  (keys:bind! dired:keymap "~" flag-backups)
  (test-user:press! "~")
  (check-equal? '("  ." "  .." "  main.ss" "D notes.txt~" "D main.o") (dired-test:lines b))
  (keys:unbind! dired:keymap "~"))

(test "files:directory of a listing is its folder, where C-x d and C-x C-f start; for a file buffer dired's entry answers #f"
  (dired-test:touch! "deep/inner/x.txt" "x\n")
  (let ([listing (dired:visit (dired-test:home-path "deep/inner"))] [file (files:visit (dired-test:home-path "deep/inner/x.txt"))]
        [started '()])
    (check-equal? (list (dired-test:home-path "deep/inner/") #f (dired-test:home-path "deep/inner/"))
      (list (files:directory listing) (dired:folder file) (files:directory file)))
    (layout:switch-to-buffer listing)
    (options:set! ask:file-name-reader
      (lambda (question . folder)
        (set! started (cons (list question (if (pair? folder) (car folder) (files:directory))) started))
        (dired-test:home-path (if (string=? question "Folder: ") "deep/inner" "deep/inner/x.txt"))))
    (dired-test:press-until-shown! "C-x d" "~/deep/inner/")
    (dired-test:press-until-shown! "C-x C-f" "x.txt")
    (options:unset! ask:file-name-reader)
    (check-equal? (list (list "Folder: " (dired-test:home-path "deep/inner/")) (list "Find file: " (dired-test:home-path "deep/inner/")))
      (reverse started))))

(test "reloading the plugin keeps its listings, their marks and their mode, and its entry in files:folder-visitors comes back"
  (dired-test:touch! "r/a.txt" "a\n")
  (let ([r (dired:visit (dired-test:home-path "r"))])
    (layout:switch-to-buffer r)
    (dired-test:goto! "a.txt")
    (test-user:press! "m")
    (reload-modules! '((dired)))
    (check-equal? (list #t '("  ." "  .." "* a.txt") dired:mode #f)
      (list (eq? r (files:visit (dired-test:home-path "r"))) (dired-test:lines r) (modes:major-mode r) (buffers:with-buffer r (files:offer-save?))))
    (dired-test:press-until-read! "g")
    (check-equal? '("  ." "  .." "* a.txt") (dired-test:lines r))
    (test-user:settle)
    (check (pair? (dired-test:drawn "dired-entry")))))

(define read-listings '())

(define (note-read b) (set! read-listings (cons (buffers:name b) read-listings)))

(define (note-mode) (set! read-listings (cons 'mode read-listings)))

(test "dired:after-read is called with a listing after each read, and dired:mode-hook when a listing takes the mode"
  (hooks:add! dired:after-read note-read)
  (hooks:add! dired:mode-hook note-mode)
  (dired-test:touch! "hooked/a.txt" "a\n")
  (dired:refresh (dired:visit (dired-test:home-path "hooked")))
  (test-runner:wait-until (lambda () (= 3 (length read-listings))))
  (hooks:remove! dired:after-read note-read)
  (hooks:remove! dired:mode-hook note-mode)
  (check-equal? '(mode "~/hooked/" "~/hooked/") (reverse read-listings)))
