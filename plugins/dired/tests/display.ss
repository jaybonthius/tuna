(import (tuna) (test) (caught-reports) (test-runner) (test-user) (options) (ask) (modes) (processes) (buffers) (views)
        (layout) (layout-split) (editing) (echo-area) (minibuffer) (completion) (files) (undo) (dired) (dired-test))

(define (set-time! name date)
  (let-values ([(status output errors) (processes:run "touch" (list "-d" date (dired-test:home-path name)) #f)])
    (unless (eqv? status 0) (error 'set-time! "touch failed" name errors))))

(dired-test:touch! "d/old.txt" "old\n")
(dired-test:touch! "d/new.txt" "new, and longer\n")
(dired-test:touch! "d/mid.c" "m\n")
(set-time! "d/old.txt" "2020-01-02 03:04")
(set-time! "d/mid.c" "2021-01-01")

(define b (dired:visit (dired-test:home-path "d")))

(layout:switch-to-buffer b)

(dired:open (dired-test:home-path "d"))

(define (sort-shown) (car (dired-test:drawn-texts "dired-sort")))

(define (summary-shown) (dired-test:drawn-texts "dired-summary"))

(define (space-shown?)
  (exists (lambda (s) (starts-with? "total used in directory " s)) (summary-shown)))

(define (starts-with? prefix s)
  (and (<= (string-length prefix) (string-length s)) (string=? prefix (substring s 0 (string-length prefix)))))

(test "s toggles the sort between name and time, newest first, in this listing only, and the header shows it"
  (check-equal? '("  ." "  .." "  mid.c" "  new.txt" "  old.txt") (dired-test:lines b))
  (dired-test:goto! "old.txt")
  (dired-test:press-until-listed! "s")
  (check-equal? (list '("  ." "  .." "  new.txt" "  mid.c" "  old.txt") "old.txt" 'time 'name)
    (list (dired-test:lines b) (dired-test:point-name) (buffers:with-buffer b (dired:sort)) (dired:sort)))
  (check-equal? "by time" (sort-shown)))

(test "C-u s reads a sort"
  (options:set! ask:line-reader (dired-test:answer "size"))
  (dired-test:press-until-listed! "C-u s")
  (options:unset! ask:line-reader)
  (check-equal? (list '("Sort by (name, time, size or extension): ") '("  ." "  .." "  new.txt" "  old.txt" "  mid.c"))
    (list (dired-test:questions) (dired-test:lines b))))

(test "C-u s sorts by any dired:sorting name, which dired:sort-by checks; dired:reverse-sort? reverses, and the header says so"
  (options:set! ask:line-reader (dired-test:answer "extension"))
  (dired-test:press-until-listed! "C-u s")
  (options:unset! ask:line-reader)
  (dired-test:questions)
  (check-equal? '("  ." "  .." "  mid.c" "  new.txt" "  old.txt") (dired-test:lines b))
  (buffers:with-buffer b (options:set-local! dired:reverse-sort? #t))
  (dired-test:press-until-listed! "g")
  (check-equal? '("  ." "  .." "  old.txt" "  new.txt" "  mid.c") (dired-test:lines b))
  (check-equal? "by extension, reversed" (sort-shown))
  (check-raises assertion-violation? (dired:sort-by b 'colour)))

(test "each entry draws its mark, mode, links, owner, group, size and time, then its name, which a click opens; the header gives the space used"
  (check-equal? '(" " " " " " " " " ") (dired-test:drawn-texts "dired-mark"))
  (check (starts-with? "-rw" (dired-test:drawn-field "dired-mode" "new.txt")))
  (check-equal? 5 (length (dired-test:drawn "dired-links")))
  (check-equal? 5 (length (dired-test:drawn "dired-owner")))
  (check-equal? 5 (length (dired-test:drawn "dired-group")))
  (check-equal? '("16" "Jan  2  2020")
    (list (dired-test:drawn-field "dired-size" "new.txt") (dired-test:drawn-field "dired-time" "old.txt")))
  (check (for-all (lambda (e) (test-user:element-attribute e "data-keymap")) (dired-test:drawn "dired-name")))
  (check (space-shown?)))

(test "( hides every column but the mark and the name, and the line of space used, as the minor mode dired:hide-details?"
  (test-user:press! "(")
  (check (buffers:with-buffer b (dired:hide-details?)))
  (check (memq dired:hide-details? (modes:active-minor-modes (dired-test:view))))
  (check-equal? '(() #f "by extension, reversed") (list (dired-test:drawn "dired-mode") (space-shown?) (sort-shown)))
  (test-user:press! "(")
  (check-equal? 5 (length (dired-test:drawn "dired-mode"))))

(test "dired:columns chooses the columns, in order, from a closed set"
  (options:set! dired:columns (list (dired:column size) (dired:column time)))
  (test-user:settle)
  (check-equal? '(0 0 5) (map (lambda (class) (length (dired-test:drawn class))) '("dired-mode" "dired-owner" "dired-size")))
  (check-equal? "--dired-columns:1ch 4ch 12ch auto 1fr"
    (test-user:element-attribute (car (dired-test:drawn "dired-folder")) "style"))
  (check-raises assertion-violation? (options:set! dired:columns '(size colour)))
  (options:unset! dired:columns))

(define (with-unit original size) (string-append (original size) "B"))

(test "sizes and times are drawn by changeable definitions"
  (advice-add! dired:size-text with-unit)
  (dired-test:press-until-listed! "g")
  (check-equal? "16B" (dired-test:drawn-field "dired-size" "new.txt"))
  (advice-remove! dired:size-text with-unit))

(test "a time within six months gives the hour, an older one the year, as ls -l does"
  (check-equal? (list "Sep 13  2020" 12) (list (dired:time-text 1600000000) (string-length (dired:time-text (time-second (current-time 'time-utc)))))))

(test "dired:folders-first? lists folders before files, and the header says so"
  (dired-test:folder! "d/zfolder")
  (buffers:with-buffer b (options:set-local! dired:reverse-sort? #f))
  (options:set! dired:folders-first? #t)
  (options:set! ask:line-reader (dired-test:answer "name"))
  (dired-test:press-until-listed! "C-u s")
  (options:unset! ask:line-reader)
  (dired-test:questions)
  (check-equal? '("  ." "  .." "  zfolder" "  mid.c" "  new.txt" "  old.txt") (dired-test:lines b))
  (test-user:settle)
  (check-equal? "by name, folders first" (sort-shown))
  (options:unset! dired:folders-first?))

(define (contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s)) (or (string=? part (substring s i (+ i n))) (loop (+ i 1)))))))

(test "dired:free-space? #f leaves the space available out of the header"
  (check (contains? (car (summary-shown)) " available "))
  (options:set! dired:free-space? #f)
  (dired-test:press-until-listed! "g")
  (check (not (contains? (car (summary-shown)) " available ")))
  (options:unset! dired:free-space?))
