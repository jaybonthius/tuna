(import (tuna) (test) (test-runner) (timers) (jobs) (jobs-test) (jobs-test progress))

(define notes '())

(define (note! x) (set! notes (cons x notes)))

(define (note-end! ended) (note! (list 'ended ended)))

(define (taken!) (let ([l (reverse notes)]) (set! notes '()) l))

(define (wait-for-notes n) (test-runner:wait-until (lambda () (>= (length notes) n))))

(jobs:define-worker (parser text emit receive)
  (let loop ([edits 0] [text text])
    (emit (list 'parsed edits text))
    (let ([v (receive)])
      (if (eq? v 'done)
          (emit (list 'idle (eof-object? (receive 0.02))))
          (let newest ([latest v] [n 1])
            (let ([more (receive 0)])
              (if (eof-object? more)
                  (loop (+ edits n) latest)
                  (newest more (+ n 1)))))))))

(test "a long-lived job keeps its state across inputs, and waits at most a time"
  (let ([parsing (jobs:start parser "abc" note! note-end!)])
    (wait-for-notes 1)
    (jobs:send! parsing "abcd")
    (wait-for-notes 2)
    (jobs:send! parsing "abcdefg")
    (wait-for-notes 3)
    (jobs:send! parsing 'done)
    (wait-for-notes 5)
    (check-equal? '((parsed 0 "abc") (parsed 1 "abcd") (parsed 2 "abcdefg") (idle #t) (ended #f)) (taken!))
    (jobs:send! parsing "after the end does nothing")
    (jobs:stop! parsing)))

;; The job waits for the test's count before it reads on, so the values
;; sent meanwhile are all waiting.
(jobs:define-worker (newest-of x emit receive)
  (import (jobs-test progress))
  (let ([first (receive)])
    (let wait () (when (< (counted) x) (sleep (make-time 'time-duration 1000000 0)) (wait)))
    (let newest ([latest first] [n 1])
      (let ([more (receive 0)])
        (if (eof-object? more)
            (emit (list n latest))
            (newest more (+ n 1)))))))

(test "receive takes values in the order sent, and (receive 0) the next of those waiting, or the end-of-file object"
  (let ([job (jobs:start newest-of (+ (counted) 1) note! note-end!)])
    (for-each (lambda (v) (jobs:send! job v)) '("a" "ab" "abcdefg"))
    (count!)
    (wait-for-notes 2)
    (check-equal? '((3 "abcdefg") (ended #f)) (taken!))))

(jobs:define-worker (waits-forever x emit receive) (emit (receive +inf.0)))

(test "an infinite time waits as no time does"
  (let ([forever (jobs:start waits-forever 0 note!)])
    (jobs:send! forever 'got)
    (wait-for-notes 1)
    (check-equal? '(got) (taken!))))

(test "a stop ends a job waiting to receive at once; on-end receives stopped, and the values sent before still run"
  (let ([waiting (jobs:start parser "x" note! note-end!)])
    (wait-for-notes 1)
    (jobs:stop! waiting)
    (wait-for-notes 2)
    (check-equal? '((parsed 0 "x") (ended stopped)) (taken!))))

(jobs:define-worker (spin x emit) (emit 'spinning) (let loop () (loop)))

(test "a stop ends a busy job, and stopping an ended job does nothing"
  (let ([spinning (jobs:start spin 0 note! note-end!)])
    (wait-for-notes 1)
    (jobs:stop! spinning)
    (wait-for-notes 2)
    (check-equal? '(spinning (ended stopped)) (taken!))
    (jobs:stop! spinning)
    (timers:sleep 0.05)
    (check-equal? '() (taken!))))

(jobs:define-worker (sleeper x emit) (emit 'sleeping) (sleep (make-time 'time-duration 100000000 0)) (emit 'woke))

(test "a job in Chez's sleep ends after the sleep returns, handing over nothing more"
  (let ([sleeping (jobs:start sleeper 0 note! note-end!)])
    (wait-for-notes 1)
    (jobs:stop! sleeping)
    (wait-for-notes 2)
    (check-equal? '(sleeping (ended stopped)) (taken!))))

(jobs:define-worker (cleans x emit)
  (import (jobs-test progress))
  (dynamic-wind #t
    void
    (lambda () (guard (c [#t (count!)]) (emit 'running) (let loop () (loop))))
    (lambda () (count!) (emit 'cleaned) (count!))))

(test "a stop cannot skip the out of a critical wind and no guard sees it; a value emitted after it is sent, then ends the job"
  (let ([before (counted)] [cleaning (jobs:start cleans 0 note! note-end!)])
    (wait-for-notes 1)
    (jobs:stop! cleaning)
    (wait-for-notes 3)
    (check-equal? '(running cleaned (ended stopped)) (taken!))
    (check-equal? 1 (- (counted) before))))

(test "jobs:send! and jobs:stop! work from any thread"
  (let ([echoing (jobs:start parser "" note! note-end!)])
    (test-runner:join (fork-task (lambda (restore) (jobs:send! echoing "sent from a thread"))))
    (wait-for-notes 2)
    (test-runner:join (fork-task (lambda (restore) (jobs:stop! echoing))))
    (wait-for-notes 3)
    (check-equal? '((parsed 0 "") (parsed 1 "sent from a thread") (ended stopped)) (taken!))))
