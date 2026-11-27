(import (tuna) (test) (test-runner) (hooks) (options) (jobs) (timers) (buffers) (files) (files-test)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(options:set! files:require-final-newline #t)

(define (cancelled-reason-of thunk)
  (guard (c [(cancelled? c) (cancelled-reason c)]) (thunk) 'not-cancelled))

(define one #f)

(test "visits of one file at once make one buffer, and files of one name visited at once get names of their own"
  (files-test:write-text! "~/one.txt" "one\n")
  (let ([visited (map test-runner:join (map (lambda (i) (spawn-task (lambda (restore) (files:visit "~/one.txt")))) (iota 5)))])
    (check-equal? '(#t 1) (list (for-all (lambda (b) (eq? b (car visited))) visited) (length (files:buffers))))
    (set! one (car visited)))
  (for-each files-test:folder! '("~/p" "~/q"))
  (for-each (lambda (p) (files-test:write-text! p "same\n")) '("~/p/same.txt" "~/q/same.txt"))
  (check-equal? '("same.txt<p>" "same.txt<q>")
    (map buffers:name (map test-runner:join (map (lambda (p) (spawn-task (lambda (restore) (files:visit p)))) '("~/p/same.txt" "~/q/same.txt"))))))

(test "saves of one buffer take turns, so the second does not mistake the first's write for another program's"
  (buffers:replace! one 1 1 "a")
  (for-each test-runner:join
    (list (spawn-task (lambda (restore) (files:save-buffer one)))
          (spawn-task (lambda (restore) (buffers:replace! one 1 1 "b") (files:save-buffer one)))
          (spawn-task (lambda (restore) (files:save-buffer one)))))
  (check-equal? '("baone\n" #f) (list (files-test:read-text "~/one.txt") (buffers:modified? one))))

(define (type-meanwhile b) (spawn-task (lambda (restore) (buffers:replace! b 1 1 "typed "))))

(test "a key typed while the job writes leaves the buffer modified: files records the version the job wrote"
  (hooks:add! files:before-save type-meanwhile)
  (buffers:replace! one 1 1 "c")
  (files:save-buffer one)
  (hooks:remove! files:before-save type-meanwhile)
  (check-equal? '("cbaone\n" "typed cbaone\n" #t) (list (files-test:read-text "~/one.txt") (files-test:text one) (buffers:modified? one))))

(define (signal-saver b) (let ([saver (current-task)]) (spawn-task (lambda (restore) (cancel-task saver 'stopped)))))

(test "a save whose waiting task is cancelled is still recorded, so the next save sees no change on disk"
  (hooks:add! files:before-save signal-saver)
  (check-equal? 'stopped (cancelled-reason-of (lambda () (files:save-buffer one))))
  (hooks:remove! files:before-save signal-saver)
  (test-runner:wait-until (lambda () (not (buffers:modified? one))))
  (check-equal? "typed cbaone\n" (files-test:read-text "~/one.txt"))
  (buffers:replace! one 1 1 "d")
  (files:save-buffer one)
  (check-equal? "dtyped cbaone\n" (files-test:read-text "~/one.txt")))

(define (stop-saver b) (let ([saver (current-task)]) (spawn-task (lambda (restore) (cancel-task saver (make-message-condition "stop"))))))

(test "a condition that is not serious, given as a waiting saver's cancel, leaves the buffer free for the next save"
  (hooks:add! files:before-save stop-saver)
  (buffers:replace! one 1 1 "s")
  (check-equal? "stop" (condition-message (cancelled-reason-of (lambda () (files:save-buffer one)))))
  (hooks:remove! files:before-save stop-saver)
  (buffers:replace! one 1 1 "t")
  (test-runner:join (spawn-task (lambda (restore) (files:save-buffer one))))
  (check-equal? '(#f "tsdtyped cbaone\n") (list (buffers:modified? one) (files-test:read-text "~/one.txt"))))

(define saved-after '())

(define (note-save b) (set! saved-after (cons (buffers:name b) saved-after)))

(define (kill-meanwhile b) (spawn-task (lambda (restore) (buffers:kill! b))))

(test "a buffer killed while its save waits is written, and gets no after-save"
  (hooks:add! files:after-save note-save)
  (hooks:add! files:before-save kill-meanwhile)
  (buffers:replace! one 1 1 "e")
  (files:save-buffer one)
  (hooks:remove! files:before-save kill-meanwhile)
  (hooks:remove! files:after-save note-save)
  (check-equal? '(#f #f () "etsdtyped cbaone\n")
    (list (buffers:live? one) (files:buffer-visiting "~/one.txt") saved-after (files-test:read-text "~/one.txt"))))

(test "an edit made while a revert reads the file is reverted too: the revert reads again"
  (let ([two (files:visit "~/one.txt")])
    (files-test:write-text! "~/one.txt" "from disk\n")
    (spawn-task (lambda (restore) (buffers:replace! two 1 1 "typed ")))
    (files:revert-from-file two)
    (check-equal? '("from disk\n" #f) (list (files-test:text two) (buffers:modified? two)))))

(define (unloaded? c) (and (error? c) (equal? "the files plugin was unloaded" (condition-message c))))

(test "unloading files ends the tasks waiting for its jobs, with an error"
  (call-with-output-file (files-test:expand "~/big.txt") (lambda (p) (display (make-string 8000000 #\x) p)))
  (check-equal? '(files:read-document)
    (map condition-who
      (test-runner:reports-during
        (lambda ()
          (let* ([visitor (spawn-task (lambda (restore) (files:visit "~/big.txt")))]
                 [unloader (spawn-task (lambda (restore) (unload-owner! (module-owner '(files)))))])
            (check-raises (lambda (c) (and (unloaded? c) (eq? 'files:read-document (condition-who c)))) (test-runner:join visitor))
            (test-runner:join unloader))))))
  (load-module! '(files))
  (test-runner:wait-until (lambda () (files:buffer-visiting "~/one.txt")))
  (check-equal? '("one.txt" "same.txt<p>" "same.txt<q>") (list-sort string<? (map buffers:name (files:buffers)))))

(test "it also ends the tasks of other modules waiting for a buffer's turn"
  (let ([large (files:visit "~/big.txt")])
    (buffers:replace! large 1 1 "y")
    (check-equal? '(files:save-buffer files:save-buffer)
      (map condition-who
        (test-runner:reports-during
          (lambda ()
            (let* ([first-saver (spawn-task (lambda (restore) (files:save-buffer large)))]
                   [second-saver (spawn-task (lambda (restore) (files:save-buffer large)))]
                   [unloader (spawn-task (lambda (restore) (unload-owner! (module-owner '(files)))))])
              (for-each (lambda (t) (check-raises (lambda (c) (and (unloaded? c) (eq? 'files:save-buffer (condition-who c)))) (test-runner:join t)))
                        (list first-saver second-saver))
              (test-runner:join unloader)))))))
  (load-module! '(files))
  (test-runner:wait-until (lambda () (files:buffer-visiting "~/big.txt")))
  (buffers:kill! (files:buffer-visiting "~/big.txt")))

;; The thread asks for a quit every tenth of a millisecond, once for each
;; time the main thread arms it, so no quit lands outside the guard but in
;; whatever runs while the guarded task waits for a job, reported there. A
;; save waits for the disk, which other programs can hold up, so the storm
;; goes on until enough saves and requests have come, giving up twenty
;; seconds on, so that a plugin that stops saving fails a check rather
;; than the file's time limit.
(test "quits landing in edits, saves, their jobs' deliveries and the bookkeeping leave each buffer saving, its file holding its text"
  (let* ([quitting #t] [armed (box #f)] [quits 0] [requests 0] [saves 0] [until (+ (real-time) 1500)]
         [count-quits (lambda (next c) (if (cancelled? c) (set! quits (+ quits 1)) (next c)))])
    (advice-add! report count-quits)
    (fork-task
      (lambda (restore)
        (let loop ()
          (when quitting
            (chez:sleep (make-time 'time-duration 100000 0))
            (when (box-cas! armed #t #f)
              (request-quit!)
              (set! requests (+ requests 1)))
            (loop)))))
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
        (let loop ()
          (when (and (< (real-time) (+ until 20000)) (or (< (real-time) until) (<= saves 30) (<= requests 30)))
            (for-each (lambda (b)
                        (set-box! armed #t)
                        (buffers:replace! b 1 1 "q")
                        (set-box! armed #t)
                        (files:save-buffer b)
                        (set! saves (+ saves 1)))
                      (files:buffers))
            (loop)))
        (set-box! armed #f)
        (timers:sleep 0.05)))
    (set! quitting #f)
    (advice-remove! report count-quits)
    (check (> saves 30))
    (check (> requests 30))
    (for-each (lambda (b) (buffers:replace! b 1 1 "!") (files:save-buffer b)) (files:buffers))
    (check-equal? (map (lambda (b) '(#f #t)) (files:buffers))
      (map (lambda (b) (list (buffers:modified? b) (string=? (files-test:text b) (files-test:read-text (files:path b))))) (files:buffers)))))

(define renamer #f)

(define renamed '())

(define (note-rename from to) (set! renamed (list (path-last from) (path-last to))))

(define (quit-as-job-ends start worker input on-result . on-end)
  (let ([t renamer])
    (if t
        (start worker input on-result
          (lambda (ended)
            (when (eq? t renamer) (cancel-task t 'quit))
            ((car on-end) ended)))
        (apply start worker input on-result on-end))))

;; A quit is for the call that is quitting, so one that arrives after it
;; has returned lands nowhere.
(define (quitting-call thunk)
  (cancelled-reason-of (lambda () (set! renamer (current-task)) (thunk))))

(define moving #f)

(test "a quit that reaches a renaming task after the job renamed the file, before the task resumes, still finds the buffer moved and files:after-rename called"
  (files-test:write-text! "~/before.txt" "before\n")
  (set! moving (files:visit "~/before.txt"))
  (hooks:add! files:after-rename note-rename)
  (advice-add! jobs:start quit-as-job-ends)
  (check-equal? 'quit (quitting-call (lambda () (files:rename-file "~/before.txt" "~/after.txt"))))
  (set! renamer #f)
  (advice-remove! jobs:start quit-as-job-ends)
  (check-equal? (list (files-test:expand "~/after.txt") "after.txt" '("before.txt" "after.txt") #t)
    (list (files:path moving) (buffers:name moving) renamed (files-test:exists? "~/after.txt"))))

(define (quit-at-first-value start worker input on-result . on-end)
  (let ([t renamer])
    (if t
        (apply start worker input (lambda (v) (when (eq? t renamer) (cancel-task t 'quit)) (on-result v)) on-end)
        (apply start worker input on-result on-end))))

(test "across file systems a rename copies then deletes; a quit once the copy is whole finds the buffer on the copy"
  (let ([other (format "/dev/shm/tuna-races-~a" (get-process-id))])
    (files:make-folder other)
    (advice-add! jobs:start quit-at-first-value)
    (check-equal? 'quit (quitting-call (lambda () (files:rename-file "~/after.txt" (string-append other "/after.txt")))))
    (set! renamer #f)
    (advice-remove! jobs:start quit-at-first-value)
    (check-equal? (list (string-append other "/after.txt") '("after.txt" "after.txt") "before\n")
      (list (files:path moving) renamed (files-test:read-text (string-append other "/after.txt"))))
    (files:delete-file other)
    (hooks:remove! files:after-rename note-rename)))

(define (stop-at-start start worker input on-result . on-end)
  (let ([j (apply start worker input on-result on-end)])
    (jobs:stop! j)
    j))

(test "a job stopped as it starts, as a quit's guard stops it, ends before its body runs: the rename raises and nothing moves"
  (files-test:write-text! "~/a.txt" "a\n")
  (let ([a (files:visit "~/a.txt")])
    (set! renamed '())
    (hooks:add! files:after-rename note-rename)
    (advice-add! jobs:start stop-at-start)
    (check-raises (lambda (c) (and (message-condition? c) (equal? "the job was stopped" (condition-message c))))
      (files:rename-file "~/a.txt" "~/b.txt"))
    (advice-remove! jobs:start stop-at-start)
    (hooks:remove! files:after-rename note-rename)
    (check-equal? (list #t #f (files-test:expand "~/a.txt") '())
      (list (files-test:exists? "~/a.txt") (files-test:exists? "~/b.txt") (files:path a) renamed))))

;; The jobs a quitting call started that have not ended, so a check waits
;; for the file to be where the job leaves it.
(define unended 0)

(define (signal-at-start start worker input on-result . on-end)
  (let ([t renamer])
    (if t
        (let ([j (apply start worker input on-result
                   (map (lambda (end)
                          (set! unended (+ unended 1))
                          (lambda (ended) (end ended) (set! unended (- unended 1))))
                        on-end))])
          (spawn-task (lambda (restore) (when (eq? t renamer) (cancel-task t 'quit))))
          j)
        (apply start worker input on-result on-end))))

(define (rename-quitting n)
  (let ([from (format "~~/f~a.txt" n)] [to (format "~~/g~a.txt" n)])
    (files-test:write-text! from "x\n")
    (let ([b (files:visit from)])
;; The pause keeps the call going, as a command does after a rename,
      ;; so the quit lands inside it.
      (quitting-call (lambda () (files:rename-file from to) (timers:sleep 0.05)))
      (set! renamer #f)
      (test-runner:wait-until (lambda () (= unended 0)))
      (list n (files-test:exists? to) (equal? (files:path b) (files-test:expand (if (files-test:exists? to) to from)))))))

(test "with quits as a C-g typed during the rename gives, whether or not the file moved, its buffer visits it where it is"
  (advice-add! jobs:start signal-at-start)
  (check-equal? '() (filter (lambda (r) (not (caddr r))) (map rename-quitting (iota 100))))
  (advice-remove! jobs:start signal-at-start))

(define saved '())

(define (note-saved b) (set! saved (cons (buffers:name b) saved)))

(test "a quit that reaches a saving task after the file is written still finds the save recorded and files:after-save called"
  (files-test:write-text! "~/saved.txt" "a\n")
  (let ([saving (files:visit "~/saved.txt")])
    (hooks:add! files:after-save note-saved)
    (buffers:replace! saving 1 1 "s")
    (advice-add! jobs:start quit-as-job-ends)
    (check-equal? 'quit (quitting-call (lambda () (files:save-buffer saving))))
    (set! renamer #f)
    (advice-remove! jobs:start quit-as-job-ends)
    (hooks:remove! files:after-save note-saved)
    (check-equal? '(("saved.txt") #f "sa\n") (list saved (buffers:modified? saving) (files-test:read-text "~/saved.txt")))))

(define order '())

(define (pausing from to)
  (set! order (cons 'entry-starts order))
  (files:visit "~/order-other.txt")
  (set! order (cons 'entry-ends order)))

(test "files:after-rename is called as the job reports its work, in another task, so an entry that pauses finishes after the rename returned"
  (files-test:write-text! "~/order-a.txt" "a\n")
  (files-test:write-text! "~/order-other.txt" "o\n")
  (hooks:add! files:after-rename pausing)
  (files:rename-file "~/order-a.txt" "~/order-c.txt")
  (set! order (cons 'rename-returned order))
  (test-runner:wait-until (lambda () (memq 'entry-ends order)))
  (hooks:remove! files:after-rename pausing)
  (check-equal? '(entry-starts rename-returned entry-ends) (reverse order)))
