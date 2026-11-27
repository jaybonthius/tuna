(import (tuna) (test) (test-runner) (hooks) (options) (ask) (commands) (keys) (tables) (timers) (document) (buffers)
        (files) (files-test))

(options:set! files:require-final-newline #t)

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(files-test:write-text! "~/notes.txt" "Buy milk.  \nCall Bob.")

(define notes (files:visit "~/notes.txt"))

(test "the page's examples: a visit, its path, the buffer visiting a path and the file buffers"
  (check-equal? (list "notes.txt" (files-test:expand "~/notes.txt") notes (list notes))
    (list (buffers:name notes) (files:path notes) (files:buffer-visiting "~/notes.txt") (files:buffers))))

(define (delete-trailing-whitespace buffer)
  (let* ([doc (buffers:document buffer)] [s (document:text doc)])
    (let loop ([i (- (string-length s) 1)] [line-end #f])
      (when (>= i 0)
        (let ([c (string-ref s i)])
          (cond
            [(char=? c #\newline) (loop (- i 1) i)]
            [(and line-end (char=? c #\space))
             (let scan ([j i])
               (if (and (> j 0) (char=? (string-ref s (- j 1)) #\space))
                   (scan (- j 1))
                   (begin
                     (buffers:replace! buffer (+ j 1) (+ i 2) "")
                     (loop (- j 1) #f))))]
            [else (loop (- i 1) #f)]))))))

(test "the page's before-save entry may edit the buffer, and the save writes the result, with the final line break asked for"
  (hooks:add! files:before-save delete-trailing-whitespace)
  (buffers:replace! notes 1 1 "Today: ")
  (check (buffers:modified? notes))
  (files:save-buffer notes)
  (check-equal? '("Today: Buy milk.\nCall Bob.\n" #f "Today: Buy milk.\nCall Bob.\n")
    (list (files-test:read-text "~/notes.txt") (buffers:modified? notes) (files-test:text notes))))

(test "run by a key, a command's buffer is the current buffer; the page's keys are bound"
  (buffers:replace! notes 1 1 "* ")
  (buffers:with-buffer notes (commands:run files:save-buffer))
  (check-equal? "* Today: Buy milk.\nCall Bob.\n" (files-test:read-text "~/notes.txt"))
  (check-equal? '(files:save-buffer files:not-modified files:save-buffers-kill-tuna)
    (map (lambda (k) (commands:command-name (tables:ref keys:global k))) '("C-x C-s" "M-~" "C-x C-c"))))

(import (files-test autosave))

(test "the page's autosave example saves modified buffers after five seconds of idle, and leaves alone a file another program changed and one the user would not save over its write protection"
  (let ([other (files:visit "~/other.txt")] [later (files:visit "~/later.txt")])
    (files-test:write-text! "~/locked.txt" "locked\n")
    (files-test:set-mode! "~/locked.txt" #o444)
    (let ([locked (files:visit "~/locked.txt")])
      (buffers:replace! notes 1 1 "+ ")
      (buffers:replace! other 1 1 "draft")
      (buffers:replace! locked 1 1 "un")
      (buffers:replace! later 1 1 "later")
      (files-test:write-text! "~/other.txt" "changed elsewhere\n")
      (options:set! ask:yes-or-no-reader (lambda (question) #f))
      (timers:set-idle! #t)
      (test-runner:wait-until (lambda () (not (or (buffers:modified? notes) (buffers:modified? later)))))
      (check-equal? '(#f #t #t #f) (map buffers:modified? (list notes other locked later)))
      (check-equal? '("+ * Today: Buy milk.\nCall Bob.\n" "changed elsewhere\n" "later\n")
        (map files-test:read-text '("~/notes.txt" "~/other.txt" "~/later.txt")))
      (unload-owner! (module-owner '(files-test autosave)))
      (files:not-modified locked)
      (files:not-modified other))))

(define asked '())

(define (note-question reply) (lambda (question) (set! asked (cons question asked)) reply))

(test "C-x C-c asks before it exits with a modified file buffer whose edits no entry of files:unsaved-kept keeps"
  (buffers:replace! notes 1 1 "! ")
  (options:set! ask:yes-or-no-reader (note-question #f))
  (commands:run files:save-buffers-kill-tuna)
  (check-equal? '("Modified buffers exist; exit anyway? ") asked))

(define (keep-notes buffer) (eq? buffer notes))

(test "with no edits to lose, it asks whether to exit only when files:confirm-exit? is on, which is off by default"
  (hooks:add! files:unsaved-kept keep-notes)
  (check-equal? #f (files:confirm-exit?))
  (set! asked '())
  (options:set! files:confirm-exit? #t)
  (options:set! ask:y-or-n-reader (note-question #f))
  (commands:run files:save-buffers-kill-tuna)
  (check-equal? '("Really exit Tuna? ") asked)
  (hooks:remove! files:unsaved-kept keep-notes))

(define (in-task thunk) (test-runner:join (spawn-task (lambda (restore) (thunk)))))

(define (revert-in b) (in-task (lambda () (buffers:with-buffer b (commands:run buffers:revert-buffer)))))

(test "buffers:revert-buffer runs the current buffer's buffers:revert-function, whose global value files sets to files:revert-from-file: a file buffer reads its file again"
  (check (eq? (buffers:revert-function) files:revert-from-file))
  (files-test:write-text! "~/r.txt" "one\n")
  (let ([r (files:visit "~/r.txt")])
    (files-test:write-text! "~/r.txt" "two\n")
    (revert-in r)
    (check-equal? "two\n" (files-test:text r))))

(define plain (buffers:make "plain" "text\n"))

(test "a buffer that visits no file and sets no value of its own gets files' refusal, which the command run reports"
  (check-equal? '(files:revert-from-file) (map condition-who (reports-during (lambda () (revert-in plain))))))

(define seen #f)

(commands:define-command (note-prefix [p (commands:prefix-argument)]) "Notes its prefix argument." (set! seen p))

(test "a command set locally runs with the prefix argument still bound"
  (buffers:with-buffer plain (options:set-local! buffers:revert-function note-prefix))
  (in-task (lambda () (parameterize ([commands:prefix-argument '(4)]) (buffers:with-buffer plain (commands:run buffers:revert-buffer)))))
  (check-equal? '(4) seen))

(test "M-x does not offer files' reverter, so a user meets one revert command"
  (check-equal? '() (tables:ref commands:command-modes files:revert-from-file #f)))
