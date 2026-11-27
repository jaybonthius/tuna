(import (tuna) (test) (test-runner) (test-user) (options) (document) (buffers) (files) (undo) (undo-log) (edits) (logs)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(options:set! undo-log:keep-log? (lambda (path) #t))

(define (text b) (document:text (buffers:document b)))

(define (visited name text)
  (let ([path (logs:home-path name)])
    (logs:write-text! path text)
    (files:visit path)))

(define (edit-batches! b n s)
  (do ([i 0 (+ i 1)]) ((= i n))
    (buffers:replace! b 1 1 s)
    (test-user:settle)))

(define big (visited "big.txt" "big\n"))

(test "an edit made while a reload of undo reads the buffer's log forms a group of its own on top of the log's history"
  (edit-batches! big 1500 (make-string 1000 #\k))
  (let ([before (edits:states big)])
    (test-runner:wait-until (lambda () (> (logs:log-size (logs:home-path "big.txt")) 1500000)))
    (reload-modules! '((undo)))
    (buffers:replace! big 1 1 "during")
    (check-equal? 1502 (length (edits:states big)))
    (let ([after (edits:states big)])
      (check-equal? (list before 1500 1501) (list (list-head after 1501) (cadr (list-ref after 1501)) (car (undo:history big)))))
    (edits:run-in big undo:undo 1)
    (check-equal? '("kkkkkk" 1500004) (list (substring (text big) 0 6) (string-length (text big))))))

(test "unloading undo-log while it reads a log ends the attach: the buffer keeps its edits and a history, and a task waiting for the history goes on"
  (reload-modules! '((undo)))
  (let ([waiter (spawn-task (lambda (restore) (length (edits:states big))))])
    (unload-owner! (module-owner '(undo-log)))
    (buffers:replace! big 1 1 "after")
    (check (number? (test-runner:join waiter)))
    (edits:run-in big undo:undo 1)
    (check-equal? '("kkkkkk" 1500004) (list (substring (text big) 0 6) (string-length (text big)))))
  (load-module! '(undo-log)))

(test "unloading undo, and so undo-log, during a burst of batches waits for the writer, so the log holds every group"
  (let ([burst (visited "burst.txt" "burst\n")])
    (edit-batches! burst 300 "b")
    (unload-owner! (module-owner '(undo)))
    (load-module! '(undo))
    (load-module! '(undo-log))
    (load-module! '(edits))
    (test-runner:wait-until (lambda () (guard (c [(error? c) #f]) (= (length (edits:states burst)) 301))))
    (edits:run-in burst undo:undo 300)
    (check-equal? "burst\n" (text burst))))

(test "two visits of one file at once attach one history"
  (let ([twice (visited "twice.txt" "twice\n")])
    (edits:run-in twice edits:insert 1 "2")
    (logs:logged-kinds (logs:home-path "twice.txt") 4)
    (buffers:kill! twice))
  (let ([visits (map test-runner:join
                     (map (lambda (i) (spawn-task (lambda (restore) (files:visit (logs:home-path "twice.txt"))))) '(1 2)))])
    (check-equal? (list #t "twice\n" '((0 #f) (1 0)))
      (list (eq? (car visits) (cadr visits)) (text (car visits)) (edits:states (car visits))))
    (edits:run-in (car visits) undo:redo 1)
    (check-equal? "2twice\n" (text (car visits)))))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(test "quits landing in typing, undo and redo, in the hooks that record them and in the log's bookkeeping leave a tree that matches the text, and the log replays to it"
  (let* ([storm (visited "storm.txt" "storm\n")]
         [quitting #t] [stopped #f] [quits 0] [rounds 0] [stressed (current-task)] [until (+ (real-time) 1500)]
         [count-quits (lambda (next c) (if (cancelled? c) (set! quits (+ quits 1)) (next c)))]
         [refused? (lambda (c)
                     (and (message-condition? c)
                          (member (condition-message c) '("no further undo information" "no further redo information"))))]
         [count-refusals (lambda (next c) (unless (refused? c) (next c)))])
    (advice-add! report count-quits)
    (advice-add! report count-refusals)
    ;; A user's quit cancels the main thread's running task from another
    ;; thread, landing up to a thousand calls after it is asked for, so the
    ;; one guard holds from before the first until after the last has
    ;; landed: a quit between two guards would end the test.
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
        (when (= quits 0)
          (fork-task
            (lambda (restore)
              (let loop ()
                (if quitting
                    (begin
                      (cancel-task stressed)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ()
          (when (< (real-time) until)
            (edits:run-in storm edits:type "s")
            (edits:run-in storm edits:insert 1 "i")
            (edits:run-in storm undo:undo 1)
            (edits:run-in storm undo:redo 1)
            (set! rounds (+ rounds 1))
            (loop)))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-refusals)
    (advice-remove! report count-quits)
    (check (> rounds 30))
    (check (> quits 30))
    (let ([final (list (text storm) (edits:states storm) (car (undo:history storm)))])
      (undo:go-to! storm 0)
      (check-equal? "storm\n" (text storm))
      (undo:go-to! storm (caddr final))
      (check-equal? final (list (text storm) (edits:states storm) (car (undo:history storm))))
      (let ([open (length (files:buffers))])
        (reload-modules! '((buffers)))
        (test-runner:wait-until (lambda () (= (length (files:buffers)) open))))
      (let ([storm (files:visit (logs:home-path "storm.txt"))])
        (check-equal? final (list (text storm) (edits:states storm) (car (undo:history storm))))))))
