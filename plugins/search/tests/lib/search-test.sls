#!tuna
(import (test-runner) (buffers) (document) (search))

(define forward (search:direction forward))

(define backward (search:direction backward))

(define (text-buffer name text) (buffers:make (buffers:free-name name) text))

(define (end-of b) (document:length (buffers:document b)))

(define (span b m)
  (and m (list (search:match-start m) (search:match-end m)
               (buffers:text-between (buffers:document b) (search:match-start m) (search:match-end m)))))

(define find-in
  (case-lambda
    [(b q position direction) (find-in b q position direction 0 (end-of b))]
    [(b q position direction start end) (find-in b q position direction start end start end)]
    [(b q position direction start end seen seen-end)
     (span b (search:find b q position direction start end seen seen-end))]))

(define (all-in b q)
  (let ([end (end-of b)])
    (let loop ([p 0] [acc '()])
      (let ([m (and (<= p end) (search:find b q p forward))])
        (if m
            (loop (if (= (search:match-start m) (search:match-end m)) (+ (search:match-end m) 1) (search:match-end m))
                  (cons (span b m) acc))
            (reverse acc))))))

(define scanned
  (case-lambda
    [(b q) (scanned b q 0 (end-of b))]
    [(b q start end) (scanned b q start end start end)]
    [(b q start end seen seen-end)
     (let ([s (search:scan b q start end start (lambda (s) (void)) seen seen-end)])
       (test-runner:wait-until (lambda () (search:scan-done? s)))
       s)]))

(define (scan-spans b s) (map (lambda (m) (span b m)) (search:scan-matches s 0 (end-of b))))

;; A resume queued while this task is paused runs only once the batch
;; has ended, and a scan follows a batch's edits at its end.
(define (end-batch)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))

(define (raised thunk)
  (guard (c [(and (who-condition? c) (message-condition? c))
             (list (condition-who c) (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))])
    (thunk)
    'none))

