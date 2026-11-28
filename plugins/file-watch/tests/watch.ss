(import (tuna) (test) (test-runner) (timers) (options) (jobs) (file-watch) (file-watch-test) (file-watch-test descriptors))

(define (home name) (file-watch-test:home name))

(define before (file-watch-test/descriptors:inotify-watch-counts))

(file-watch-test:folder! "w")
(file-watch-test:write! "w/a.txt" "one\n")
(file-watch-test:write! "w/b.txt" "one\n")

(define on-main-thread #f)

(define main-thread (get-thread-id))

(define (main-thread-recorder entry kind)
  (set! on-main-thread (= (get-thread-id) main-thread))
  (file-watch-test:recorder entry kind))

(test "a file written in place is reported once, with its path and changed, on the main thread, and the watch is active"
  (let ([w (file-watch:watch! (home "w/a.txt") main-thread-recorder)])
    (check (file-watch:active? w))
    (check-equal? (home "w/a.txt") (file-watch:path w))
    (file-watch-test:write! "w/a.txt" "two\n")
    (file-watch-test:wait-for-calls 1)
    (file-watch-test:mark!)
    (check-equal? (list (list (home "w/a.txt") 'changed)) (file-watch-test:take-calls!))
    (check-equal? #t on-main-thread)
    (file-watch:unwatch! w)))

(test "a new file renamed over the watched one is one call, changed; the temporary name makes no call to that watch"
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)])
    (file-watch-test:write-by-rename! "w/a.txt" "three\n")
    (file-watch-test:wait-for-calls 1)
    (file-watch-test:mark!)
    (check-equal? (list (list (home "w/a.txt") 'changed)) (file-watch-test:take-calls!))
    (file-watch:unwatch! w)))

(test "a watched folder reports its entries: a creation, a deletion, and a rename as the old name deleted and the new created"
  (file-watch-test:folder! "f")
  (file-watch-test:write! "f/old.txt" "old\n")
  (file-watch-test:write! "f/doomed.txt" "doomed\n")
  (options:set! file-watch:delay 0.3)
  (let ([w (file-watch:watch! (home "f/") file-watch-test:recorder)])
    (close-port (open-file-output-port (home "f/new.txt")))
    (delete-file (home "f/doomed.txt"))
    (rename-file (home "f/old.txt") (home "f/renamed.txt"))
    (file-watch-test:wait-for-calls 4)
    (file-watch-test:mark!)
    (check-equal? (list (list (home "f/new.txt") 'created) (list (home "f/doomed.txt") 'deleted)
                        (list (home "f/old.txt") 'deleted) (list (home "f/renamed.txt") 'created))
      (file-watch-test:take-calls!))
    (options:set! file-watch:delay 0.01)
    (file-watch:unwatch! w)))

(test "a deletion and then a creation of a watched file within one burst is one call, changed"
  (options:set! file-watch:delay 0.3)
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)])
    (delete-file (home "w/a.txt"))
    (file-watch-test:write! "w/a.txt" "four\n")
    (file-watch-test:wait-for-calls 1)
    (file-watch-test:mark!)
    (check-equal? (list (list (home "w/a.txt") 'changed)) (file-watch-test:take-calls!))
    (file-watch:unwatch! w))
  (options:set! file-watch:delay 0.01))

(test "of two watches on files of one folder, only the changed file's handler is called, and one inotify watch serves both"
  (let* ([a-calls '()] [b-calls '()]
         [a (file-watch:watch! (home "w/a.txt") (lambda (entry kind) (set! a-calls (cons kind a-calls))))]
         [b (file-watch:watch! (home "w/b.txt") (lambda (entry kind) (set! b-calls (cons kind b-calls))))])
    (check-equal? (cons 1 before) (list-sort < (file-watch-test/descriptors:inotify-watch-counts)))
    (file-watch-test:write! "w/b.txt" "two\n")
    (test-runner:wait-until (lambda () (pair? b-calls)))
    (file-watch-test:mark!)
    (check-equal? '(() (changed)) (list a-calls b-calls))
    (file-watch:unwatch! a)
    (file-watch:unwatch! b)))

(test "after unwatch! no call comes, and the last unwatch! ends the job and closes the inotify instance"
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)])
    (file-watch-test:write! "w/a.txt" "five\n")
    (file-watch:unwatch! w)
    (file-watch-test:mark!)
    (check-equal? '() (file-watch-test:take-calls!))
    (check-equal? #f (file-watch:active? w))
    (test-runner:wait-until (lambda () (equal? before (file-watch-test/descriptors:inotify-watch-counts))))
    (file-watch:unwatch! w)))

(test "a path whose folder does not exist gives an inactive watch at once, and raises nothing"
  (let ([w (file-watch:watch! (home "missing/x.txt") file-watch-test:recorder)])
    (check-equal? #f (file-watch:active? w))
    (file-watch:unwatch! w)
    (test-runner:wait-until (lambda () (equal? before (file-watch-test/descriptors:inotify-watch-counts))))))

(test "a watch the kernel refuses, as on a folder the user may not read, is inactive at once, and raises nothing"
  (file-watch-test:folder! "locked")
  (chmod (home "locked") #o000)
  (let ([w (file-watch:watch! (home "locked/x.txt") file-watch-test:recorder)])
    (check-equal? #f (file-watch:active? w))
    (file-watch:unwatch! w))
  (chmod (home "locked") #o755))

(test "a watched folder that is removed calls its handler with the watched path and stopped, and the watch is no longer active"
  (file-watch-test:folder! "gone")
  (let ([w (file-watch:watch! (home "gone") file-watch-test:recorder)])
    (delete-directory (home "gone"))
    (file-watch-test:wait-for-calls 1)
    (check-equal? (list (list (home "gone") 'stopped)) (file-watch-test:take-calls!))
    (check-equal? #f (file-watch:active? w))
    (file-watch:unwatch! w)))

(test "a watch! that returns sees a write made at once after it"
  (let ([w (file-watch:watch! (home "w/b.txt") file-watch-test:recorder)])
    (file-watch-test:write! "w/b.txt" "three\n")
    (file-watch-test:wait-for-calls 1)
    (check-equal? (list (list (home "w/b.txt") 'changed)) (file-watch-test:take-calls!))
    (file-watch:unwatch! w)))

(test "bad arguments raise assertion violations naming file-watch:watch!"
  (for-each
    (lambda (thunk)
      (check-equal? 'file-watch:watch!
        (guard (c [(assertion-violation? c) (condition-who c)]) (thunk) 'nothing)))
    (list (lambda () (file-watch:watch! 'path file-watch-test:recorder))
          (lambda () (file-watch:watch! "relative/a.txt" file-watch-test:recorder))
          (lambda () (file-watch:watch! (home "w/a.txt") 'handler))))
  (check-raises assertion-violation? (file-watch:unwatch! 'watch))
  (check-equal? #f (file-watch:watch? 'watch)))

(test "a handler that raises is reported, and other handlers and later events go on"
  (let* ([raising (file-watch:watch! (home "w/a.txt") (lambda (entry kind) (error 'raising-handler "boom")))]
         [other (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
         [reports (test-runner:reports-during (lambda () (file-watch-test:write! "w/a.txt" "six\n")) 1)])
    (check-equal? '(raising-handler) (map condition-who reports))
    (file-watch-test:wait-for-calls 1)
    (file-watch-test:take-calls!)
    (test-runner:reports-during (lambda () (file-watch-test:write! "w/a.txt" "seven\n")) 1)
    (file-watch-test:wait-for-calls 1)
    (check-equal? (list (list (home "w/a.txt") 'changed)) (file-watch-test:take-calls!))
    (file-watch:unwatch! raising)
    (file-watch:unwatch! other)))

;; The calls come on the main thread, after the job's report, so the gaps
;; between them may exceed file-watch:longest-burst by that delivery, which
;; a loaded machine stretches; without the limit there would be one call,
;; seconds after the writes start.
(test "a burst that never goes quiet is reported at least every file-watch:longest-burst seconds"
  (options:set! file-watch:delay 0.2 file-watch:longest-burst 0.3)
  (let ([times '()])
    (let ([w (file-watch:watch! (home "w/a.txt") (lambda (entry kind) (set! times (cons (real-time) times))))])
      (let ([start (real-time)])
        (let loop ()
          (when (< (- (real-time) start) 3000)
            (file-watch-test:write! "w/a.txt" (number->string (real-time)))
            (timers:sleep 0.05)
            (loop))))
      (let ([gaps (let loop ([times times] [gaps '()])
                    (if (or (null? times) (null? (cdr times))) gaps (loop (cdr times) (cons (- (car times) (cadr times)) gaps))))])
        (check (>= (length times) 5))
        (check (for-all (lambda (gap) (< gap 800)) gaps)))
      (file-watch:unwatch! w)))
  (options:set! file-watch:delay 0.01)
  (options:unset! file-watch:longest-burst))

(file-watch-test:write! "w/c.txt" "one\n")

(import (file-watch-test watcher))

(test "a watch ends when the module that made it unloads, and its handler is not called again"
  (let ([w file-watch-test/watcher:watch])
    (check (file-watch:active? w))
    (unload-owner! (module-owner '(file-watch-test watcher)))
    (check-equal? #f (file-watch:active? w))
    (file-watch-test:write! "w/c.txt" "two\n")
    (file-watch-test:mark!)
    (check-equal? '() (file-watch-test:take-calls!))))

(define (spin seconds)
  (let ([until (+ (real-time) (* seconds 1000))])
    (let loop () (when (< (real-time) until) (loop)))))

(define (read-number path) (call-with-input-file path read))

;; The job blocks once 64 batches wait for a busy main thread, so it reads
;; no more events, and the kernel's queue then overflows.
(test "when the kernel's event queue overflows, every handler is called with its watched path and unknown"
  (file-watch-test:folder! "many")
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
        [folder (file-watch:watch! (home "many") (lambda (entry kind) (void)))]
        [limit (read-number "/proc/sys/fs/inotify/max_queued_events")])
    (do ([i 0 (+ i 1)]) ((= i 70))
      (file-watch-test:write! "w/a.txt" (number->string i))
      (spin 0.03))
    (do ([i 0 (+ i 1)]) ((> i limit))
      (close-port (open-file-output-port (home (format "many/~a" i)))))
    (test-runner:wait-until (lambda () (member (list (home "w/a.txt") 'unknown) (file-watch-test:calls))))
    (file-watch:unwatch! w)
    (file-watch:unwatch! folder)
    (file-watch-test:take-calls!)))

(test "setting file-watch:delay while watches exist takes effect at once"
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)])
    (options:set! file-watch:delay 0.3)
    (let ([written (real-time)])
      (file-watch-test:write! "w/a.txt" "slow")
      (file-watch-test:wait-for-calls 1)
      (check (>= (- (real-time) written) 300)))
    (file-watch-test:take-calls!)
    (options:set! file-watch:delay 0.01)
    (file-watch:unwatch! w)))

(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix)) (string=? prefix (substring s 0 (string-length prefix)))))

(define (task-file task name) (call-with-input-file (format "/proc/self/task/~a/~a" task name) get-string-all))

(define (voluntary-switches task)
  (let ([p (open-string-input-port (task-file task "status"))])
    (let loop ()
      (let ([line (get-line p)])
        (if (starts-with? line "voluntary_ctxt_switches:")
            (string->number (list->string (filter char-numeric? (string->list line))))
            (loop))))))

;; This file loads no plugin with a thread of its own in poll, so the one
;; thread there is the job.
(define (poll-wakes)
  (map voluntary-switches
       (filter (lambda (task) (starts-with? (task-file task "wchan") "do_poll")) (directory-list "/proc/self/task"))))

;; The second of idleness is the behaviour under test: a job that wakes on
;; a timer or a poll timeout would switch in it.
(test "while watches exist and nothing happens, the job sleeps in poll and is never woken"
  (file-watch-test:folder! "quiet")
  (let ([w (file-watch:watch! (home "quiet") file-watch-test:recorder)])
    (test-runner:wait-until (lambda () (= 1 (length (poll-wakes)))))
    (let ([before (poll-wakes)])
      (timers:sleep 1)
      (check-equal? before (poll-wakes)))
    (file-watch:unwatch! w)))

(define (on-message message act)
  (lambda (next job sent)
    (next job sent)
    (when (equal? sent message) (act))))

(test "when the job ends by its stop message, the main thread writes nothing through the numbers it freed"
  (let* ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
         [held (file-watch-test/descriptors:watch-descriptors)]
         [taken '()]
         [take (on-message 'stop (lambda () (set! taken (file-watch-test/descriptors:take-freed! held 2))))])
    (advice-add! jobs:send! take)
    (file-watch:unwatch! w)
    (advice-remove! jobs:send! take)
    (check-equal? '() (file-watch-test/descriptors:written taken))
    (check-equal? '() (file-watch-test/descriptors:watch-descriptors))))

(test "when jobs stops the job as file-watch unloads, before file-watch's own unload action runs, the main thread writes nothing through the numbers the job freed"
  (file-watch-test:folder! "kept")
  (let* ([w (file-watch:watch! (home "kept") file-watch-test:recorder)]
         [held (file-watch-test/descriptors:watch-descriptors)]
         [taken '()]
         [take (on-message 'stop
                 (lambda ()
                   (call-with-output-file (string-append (getenv "HOME") "/kept/event") (lambda (p) (put-string p "wakes the job, which jobs has told to stop")) 'replace)
                   (set! taken (file-watch-test/descriptors:take-freed! held 2))))])
    (advice-add! jobs:send! take)
    (reload-modules! '((file-watch)))
    (advice-remove! jobs:send! take)
    (check-equal? '() (file-watch-test/descriptors:written taken))
    (check-equal? '() (file-watch-test/descriptors:watch-descriptors))
    (file-watch-test:take-calls!)))

;; A cancel lands within about a thousand calls, unless cancels are held
;; off, and then soon after they are allowed again.
(define (cancel-here!)
  (cancel-task (current-task) 'test)
  (spin 0.05))

(test "a cancel between the stop message and its wake waits until the instance has ended: the job closes its numbers, the main thread writes through none of them, and closes its own"
  (let* ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
         [held (file-watch-test/descriptors:watch-descriptors)]
         [taken '()]
         [take (on-message 'stop (lambda () (cancel-here!) (set! taken (file-watch-test/descriptors:take-freed! held 2))))])
    (advice-add! jobs:send! take)
    (check-equal? 'cancelled (guard (c [(cancelled? c) 'cancelled]) (file-watch:unwatch! w) (spin 0.05) 'returned))
    (advice-remove! jobs:send! take)
    (check-equal? '() (file-watch-test/descriptors:written taken))
    (check-equal? '() (file-watch-test/descriptors:watch-descriptors))))

(test "a cancel between a timing message and its wake loses only the wake: the job takes the timing at its next event"
  (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
        [cancel (lambda (next job sent) (next job sent) (when (vector? sent) (cancel-here!)))])
    (advice-add! jobs:send! cancel)
    (check-equal? 'cancelled (guard (c [(cancelled? c) 'cancelled]) (options:set! file-watch:delay 0.3) 'returned))
    (advice-remove! jobs:send! cancel)
    (let ([written (real-time)])
      (file-watch-test:write! "w/a.txt" "after the cancel")
      (file-watch-test:wait-for-calls 1)
      (check (>= (- (real-time) written) 300)))
    (file-watch-test:take-calls!)
    (options:set! file-watch:delay 0.01)
    (file-watch:unwatch! w)))

(test "when the job raises, the main thread writes nothing through the numbers it freed, and closes its own once the job's end reaches it"
  (let* ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)]
         [held (file-watch-test/descriptors:watch-descriptors)]
         [spoil (lambda (next job sent) (next job (if (vector? sent) 'not-a-timing sent)))]
         [taken '()]
         [reports (test-runner:reports-during
                    (lambda ()
                      (advice-add! jobs:send! spoil)
                      (options:set! file-watch:delay 0.02)
                      (advice-remove! jobs:send! spoil)
                      (set! taken (file-watch-test/descriptors:take-freed! held 2))
                      (options:set! file-watch:delay 0.01))
                    1)])
    (check-equal? '(vector-ref) (map condition-who reports))
    (check-equal? '() (file-watch-test/descriptors:written taken))
    (test-runner:wait-until (lambda () (null? (file-watch-test/descriptors:watch-descriptors))))
    (check-equal? #f (file-watch:active? w))
    (file-watch-test:take-calls!)
    (file-watch:unwatch! w)))

(define (no-descriptors?) (null? (file-watch-test/descriptors:watch-descriptors)))

(test "a cancel as a watch starts its instance waits until the watch is made, so ending the watch ends the instance and closes every descriptor"
  (test-runner:wait-until no-descriptors?)
  (let* ([w #f]
         [cancel (lambda (next . arguments) (let ([job (apply next arguments)]) (cancel-here!) job))])
    (advice-add! jobs:start cancel)
    (check-equal? 'cancelled
      (guard (c [(cancelled? c) 'cancelled])
        (set! w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder))
        (spin 0.05)
        'returned))
    (advice-remove! jobs:start cancel)
    (check (file-watch:watch? w))
    (when (file-watch:watch? w) (file-watch:unwatch! w))
    (test-runner:wait-until no-descriptors?)))

(test "a watch whose instance cannot start is inactive, and leaves no descriptor open"
  (test-runner:wait-until no-descriptors?)
  (let ([refuse (lambda (next . arguments) (error 'refuse "no job"))])
    (advice-add! jobs:start refuse)
    (let ([w (file-watch:watch! (home "w/a.txt") file-watch-test:recorder)])
      (advice-remove! jobs:start refuse)
      (check-equal? '(#f #t) (list (file-watch:active? w) (no-descriptors?)))
      (file-watch:unwatch! w))))
