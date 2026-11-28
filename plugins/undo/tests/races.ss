(import (tuna) (test) (test-runner) (commands) (buffers) (undo) (undo-test edits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (states b) (map (lambda (s) (list (car s) (cadr s))) (cddr (undo:history b))))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(test "a quit that lands in an edit group's body undoes the body's edits"
  (let* ([q (buffers:make "quit" "\n")]
         [body (spawn-task
                 (lambda (restore)
                   (undo:with-edit-group q
                     (buffers:replace! q 1 1 "q")
                     (cancel-task (current-task))
                     (let loop () (loop)))))])
    (check-equal? '()
      (undo-test/edits:reports-during (lambda () (check-raises cancelled? (test-runner:join body)))))
    (check-equal? '("\n" ((0 #f))) (list (undo-test/edits:text q) (states q)))))

(test "quits landing in typing, undo and redo, and in the hooks that record them, leave a tree that still matches the text"
  (let* ([storm (buffers:make "storm" "storm\n")]
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
            (undo-test/edits:run-in storm undo-test/edits:type "s")
            (undo-test/edits:run-in storm undo-test/edits:insert 1 "i")
            (undo-test/edits:run-in storm undo:undo 1)
            (undo-test/edits:run-in storm undo:redo 1)
            (set! rounds (+ rounds 1))
            (loop)))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-refusals)
    (advice-remove! report count-quits)
    (check (> rounds 30))
    (check (> quits 30))
    (let ([final (list (undo-test/edits:text storm) (states storm) (car (undo:history storm)))])
      (undo:go-to! storm 0)
      (check-equal? "storm\n" (undo-test/edits:text storm))
      (undo:go-to! storm (caddr final))
      (check-equal? final (list (undo-test/edits:text storm) (states storm) (car (undo:history storm))))))
  (undo-test/edits:take-said!))
