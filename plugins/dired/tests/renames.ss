(import (tuna) (test) (caught-reports) (test-runner) (test-user) (hooks) (options) (ask) (buffers) (views) (layout)
        (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(dired-test:touch! "proj/src/main.c" "int main;\n")
(dired-test:touch! "proj/notes.txt" "notes\n")

(define top (dired:visit (dired-test:home-path "proj")))

(define src (dired:visit (dired-test:home-path "proj/src")))

(define renamed '())

(define (note-rename from to) (set! renamed (cons (list from to) renamed)))

(test "a rename by any caller moves each listing of the renamed folder, or of a folder under it, to the new path, with its marks and points"
  (layout:switch-to-buffer src)
  (dired-test:goto! "main.c")
  (test-user:press! "m")
  (hooks:add! files:after-rename note-rename)
  (files:rename-file (dired-test:home-path "proj") (dired-test:home-path "work"))
  (hooks:remove! files:after-rename note-rename)
  (check-equal? (list (list (list (dired-test:home-path "proj") (dired-test:home-path "work")))
                      "~/work/" (dired-test:home-path "work/") "~/work/src/" (dired-test:home-path "work/src/"))
    (list renamed (buffers:name top) (dired:folder top) (buffers:name src) (dired:folder src)))
  (check-equal? (list '("  ." "  .." "* main.c") "main.c" (map dired-test:home-path '("work/src/." "work/src/.." "work/src/main.c")))
    (list (dired-test:lines src) (dired-test:point-name) (map dired:entry-path (dired-test:entries src))))
  (dired-test:press-until-read! "g")
  (check-equal? '("  ." "  .." "* main.c") (dired-test:lines src)))

(test "a listing already naming the new path is killed; the moved listing stays, is read again and shows in the killed listing's views"
  (dired-test:folder! "fresh")
  (let ([fresh (dired:visit (dired-test:home-path "fresh"))])
    (layout:switch-to-buffer fresh)
    (dired-test:relisted! src
      (lambda () (files:rename-file (dired-test:home-path "work/src") (dired-test:home-path "fresh") (file-options no-fail))))
    (check-equal? '(#f "~/fresh/" "~/fresh/" ("  ." "  .." "* main.c"))
      (list (buffers:live? fresh) (buffers:name src) (buffers:name (views:buffer (dired-test:view))) (dired-test:lines src)))))

(test "R on a folder renames it, and its listing follows"
  (layout:switch-to-buffer top)
  (dired-test:folder! "work/docs")
  (let ([docs (dired:visit (dired-test:home-path "work/docs"))])
    (dired-test:press-until-read! "g")
    (dired-test:goto! "docs")
    (options:set! ask:file-name-reader (dired-test:answer "~/work/papers"))
    (dired-test:press-for-message! "R")
    (options:unset! ask:file-name-reader)
    (check-equal? '(("Rename docs to: ") "~/work/papers/" ("  ." "  .." "  notes.txt" "  papers"))
      (list (dired-test:questions) (buffers:name docs) (dired-test:lines top)))))
