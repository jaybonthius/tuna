#!tuna
(import (caught-reports) (test-runner) (test-user) (echo-area) (document) (buffers) (views) (layout) (modes) (chez-scheme) (minibuffer) (completion))

(define (home-path name) (string-append (getenv "HOME") "/" name))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (write-file! name text)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep (make-time 'time-duration 10000000 0)) (resume void)))))
  (call-with-output-file (home-path name) (lambda (p) (put-string p text)) 'replace))

(define (view) (layout:selected-view))

(define (show! b) (views:set-buffer! (view) b) b)

(define (scheme-buffer! name text)
  (let ([b (show! (buffers:make name text))])
    (modes:set-major-mode chez-scheme:mode b)
    b))

(define (text b) (document:text (buffers:document b)))

(define (position-of b string offset)
  (let* ([t (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i n)) string)
          (document:position (buffers:document b) (+ i offset) (document:unit characters))
          (loop (+ i 1))))))

(define (at! b string offset) (views:set-point! (view) (position-of b string offset)))

(define (mark-at! b string offset) (views:set-mark! (view) (position-of b string offset)))

(define (lines s)
  (let loop ([i 0] [from 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (if (= from i) acc (cons (substring s from i) acc)))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s from i) acc))]
      [else (loop (+ i 1) from acc)])))

(define (log-tail n)
  (let ([logged (lines (text (buffers:find "*Messages*")))])
    (list-tail logged (max 0 (- (length logged) n)))))

(define (prompt) (minibuffer:current-prompt))

(define (prompt-text) (text (views:buffer (minibuffer:prompt-view (prompt)))))

(define (input) (minibuffer:input (prompt)))

(define (input-point) (- (views:point (minibuffer:prompt-view (prompt))) (minibuffer:input-start (prompt))))

(define (prompt-message)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-message")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(define (session) (views:call-with-view (view) completion:current-session))

(define (session-texts)
  (let* ([s (session)] [ms (completion:session-matches s)])
    (map (lambda (k) (completion:text s (completion:matches-ref ms k))) (iota (completion:matches-count ms)))))

(define (reports-during thunk)
  (map (lambda (c)
         (if (cancelled? c)
             'cancelled
             (list (and (who-condition? c) (condition-who c)) (and (message-condition? c) (condition-message c)))))
       (caught-reports:during thunk)))

;; A command that pauses, as to save a file or reload a module, goes on
;; after the keys have settled; it ends with a message or a report.
(define (after-message thunk)
  (echo-area:message! "")
  (thunk)
  (test-runner:wait-until echo-area:current-message)
  (echo-area:current-message))

;; As in Emacs, the answer to a y-or-n question is echoed with it, a
;; message the command's own then follows; the log holds both.
(define (logged-after n thunk)
  (let ([before (length (log-tail 100000))])
    (thunk)
    (test-runner:wait-until (lambda () (>= (length (log-tail 100000)) (+ before n))))
    (list-tail (log-tail 100000) before)))

(define (eval! text prefix)
  (test-user:press! (if prefix (string-append prefix " M-:") "M-:"))
  (test-user:type! text)
  (test-user:press! "RET"))
