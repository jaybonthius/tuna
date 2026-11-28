(import (tuna) (test) (test-runner) (test-user) (options) (hooks) (processes) (document) (buffers) (views) (layout)
        (layout-split) (editing) (undo) (files) (auto-revert) (files-test) (file-watch-test) (auto-revert-test))

(define (home name) (file-watch-test:home name))

(define (numbered-lines n) (apply string-append (map (lambda (i) (format "line ~a\n" i)) (iota n))))

(define (line-position b k)
  (let ([text (auto-revert-test:text b)])
    (let loop ([i 0] [line 0])
      (if (= line k) (+ i 1) (loop (+ i 1) (if (char=? (string-ref text i) #\newline) (+ line 1) line))))))

(define reverts 0)

(define (count-revert buffer) (set! reverts (+ reverts 1)))

(hooks:add! files:after-revert count-revert)

(file-watch-test:write! "notes.txt" "one\ntwo\n")

(define notes (files:visit (home "notes.txt")))

(define v (auto-revert-test:show! notes))

(test "an unmodified buffer shown in a view whose file another program overwrites holds the file's text after the quiet delay, unmodified; files:after-revert ran, and the echo area says Reverted"
  (set! reverts 0)
  (file-watch-test:write! "notes.txt" "one\ntwo\nthree\n")
  (auto-revert-test:wait-for-text notes "one\ntwo\nthree\n")
  (check-equal? '("Reverted notes.txt") (files-test:take-said!))
  (check-equal? '(#f 1) (list (buffers:modified? notes) reverts)))

(test "a file replaced by a write to a new file renamed over it reloads the same way"
  (file-watch-test:write-by-rename! "notes.txt" "one\ntwo\nthree\nfour\n")
  (auto-revert-test:wait-for-text notes "one\ntwo\nthree\nfour\n")
  (check-equal? #f (buffers:modified? notes)))

(file-watch-test:write! "long.txt" (numbered-lines 600))

(define long (files:visit (home "long.txt")))

(define (long-with changes)
  (apply string-append (map (lambda (i) (let ([c (assv i changes)]) (if c (cdr c) (format "line ~a\n" i)))) (iota 600))))

(test "lines 5 and 500 changed on disk replace only those two hunks, in one batch, and a cursor on line 250 stays on its text"
  (auto-revert-test:show! long)
  (views:set-point! v (+ (line-position long 250) 2))
  (let ([version (buffers:version long)])
    (file-watch-test:write! "long.txt" (long-with (list (cons 5 "changed five\n") (cons 500 "changed five hundred\n"))))
    (auto-revert-test:wait-for-text long (long-with (list (cons 5 "changed five\n") (cons 500 "changed five hundred\n"))))
    (check-equal? 2 (length (buffers:edits-since long version)))
    (check-equal? (+ (line-position long 250) 2) (views:point v))))

(test "one undo takes the whole reload back, and the buffer is then modified, since it differs from the file"
  (test-user:press! "C-/")
  (check-equal? (numbered-lines 600) (auto-revert-test:text long))
  (check-equal? #t (buffers:modified? long))
  (files:revert-from-file long))

(test "a cursor inside a changed line lands at the start or the end of its replacement"
  (let* ([start (line-position long 10)] [inside (+ start 3)])
    (views:set-point! v inside)
    (let ([before (auto-revert-test:text long)])
      (file-watch-test:write! "long.txt"
        (string-append (substring before 0 (- start 1)) "LINE TEN\n" (substring before (+ start (string-length "line 10\n") -1) (string-length before))))
      (test-runner:wait-until (lambda () (not (equal? before (auto-revert-test:text long)))))
      (check (memv (views:point v) (list start (+ start (string-length "LINE TEN"))))))))

(test "a line inserted above the cursor keeps the cursor on the same text"
  (let* ([text (auto-revert-test:text long)] [at (line-position long 300)])
    (views:set-point! v at)
    (file-watch-test:write! "long.txt" (string-append "new first line\n" text))
    (auto-revert-test:wait-for-text long (string-append "new first line\n" text))
    (check-equal? (+ at (string-length "new first line\n")) (views:point v))))

(test "a view whose cursor is at the end of the buffer has it at the new end once lines are appended; another view of the buffer, not at the end, keeps its cursor"
  (auto-revert-test:show! notes)
  (test-user:press! "C-x 2 C-x o")
  (let ([other (layout:selected-view)] [text (auto-revert-test:text notes)])
    (views:set-point! other 3)
    (test-user:press! "C-x o")
    (views:set-point! v (- (document:length (buffers:document notes)) 1))
    (file-watch-test:write! "notes.txt" (string-append text "five\nsix\n"))
    (auto-revert-test:wait-for-text notes (string-append text "five\nsix\n"))
    (check-equal? (- (document:length (buffers:document notes)) 1) (views:point v))
    (check-equal? 3 (views:point other))
    (test-user:press! "C-x 1")))

(test "a file deleted on disk leaves its unmodified buffer as it is, with no message"
  (file-watch-test:write! "gone.txt" "gone\n")
  (let ([gone (files:visit (home "gone.txt"))])
    (files-test:take-said!)
    (delete-file (home "gone.txt"))
    (auto-revert:check gone)
    (check-equal? '("gone\n" #f ()) (list (auto-revert-test:text gone) (buffers:modified? gone) (files-test:take-said!)))))

(define (touch! name)
  (let-values ([(status output errors) (processes:run "touch" (list "-d" "2030-01-01" (home name)) #f)])
    (unless (eqv? status 0) (error 'touch! "touch failed" name errors))))

(test "a file touched with its bytes the same reloads nothing"
  (set! reverts 0)
  (touch! "notes.txt")
  (auto-revert:check notes)
  (check-equal? 0 reverts))

(test "Tuna's own save reloads nothing and marks nothing Stale"
  (set! reverts 0)
  (buffers:replace! notes 1 1 "saved ")
  (files:save-buffer notes)
  (auto-revert:check notes)
  (check-equal? '(0 #f) (list reverts (auto-revert:stale? notes))))

(test "with auto-revert:verbose? false a reload says nothing"
  (options:set! auto-revert:verbose? #f)
  (files-test:take-said!)
  (file-watch-test:write! "notes.txt" "quiet\n")
  (auto-revert-test:wait-for-text notes "quiet\n")
  (check-equal? '() (files-test:take-said!))
  (options:unset! auto-revert:verbose?))

(test "a file that cannot be read is not reloaded, and nothing is said"
  (file-watch-test:write! "locked.txt" "locked\n")
  (let ([locked (files:visit (home "locked.txt"))])
    (files-test:take-said!)
    (file-watch-test:write! "locked.txt.new" "locked, changed\n")
    (chmod (home "locked.txt.new") #o000)
    (rename-file (home "locked.txt.new") (home "locked.txt"))
    (auto-revert:check locked)
    (check-equal? '("locked\n" ()) (list (auto-revert-test:text locked) (files-test:take-said!)))
    (chmod (home "locked.txt") #o644)))

(test "an active region whose end lies in a replaced hunk has that end at the hunk's start or end; an end on unchanged text stays"
  (auto-revert-test:show! long)
  (let* ([text (auto-revert-test:text long)]
         [unchanged (line-position long 20)] [inside (+ (line-position long 40) 4)])
    (views:set-mark! v unchanged)
    (views:set-point! v inside)
    (let ([start (line-position long 40)])
      (file-watch-test:write! "long.txt"
        (string-append (substring text 0 (- start 1)) "replaced line\n" (substring text (- (line-position long 41) 1) (string-length text))))
      (test-runner:wait-until (lambda () (not (equal? text (auto-revert-test:text long)))))
      (check-equal? unchanged (views:mark v))
      (check (<= start (views:point v) (+ start (string-length "replaced line"))))
      (check (not (= (views:point v) inside))))))
