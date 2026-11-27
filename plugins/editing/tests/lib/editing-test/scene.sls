#!tuna
(import (test-runner) (options) (ask) (commands) (test-user) (layout) (views) (buffers) (document) (kill-ring) (editing-test md))

(define (view) (layout:selected-view))

;; A user reaches a new buffer by a command, which ends a run of kills,
;; yanks or line motions; C-g is one that changes nothing else. A user
;; sees the buffer before clicking it, so the screen is drawn by return.
(define (show! content point . more-points)
  (test-user:press! "C-g")
  (let ([b (buffers:make (buffers:free-name "*test*") content)] [v (view)])
    (views:set-buffer! v b)
    (views:set-point! v point)
    (for-each (lambda (p) (views:add-cursor! v p)) more-points)
    (test-user:settle)
    b))

(define (show-marked! text)
  (test-user:press! "C-g")
  (test-user:show! text))

(define (text) (document:text (buffers:document (views:buffer (view)))))

(define (cursors)
  (map (lambda (c) (list (views:cursor-point c) (views:cursor-mark c))) (views:cursors (view))))

(define (state) (list (text) (cursors)))

(define (root) (car (document:datums (buffers:document (views:buffer (view))))))

(define (blocks) (cddr (root)))

(define (kills n) (map kill-ring:text (list-head (kill-ring:entries) n)))

(define (current-kills) (map (lambda (kill) (kill-ring:text (list kill))) (kill-ring:current)))

(define (run command . args) (views:with-view (view) (apply commands:run command args)))

(define (lock! from to) (buffers:add-span! (buffers:layer (views:buffer (view)) editing-test/md:locked) from to 'locked))

(define (raised? who text)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? text (condition-message c)))))

(define (refused? report) (eq? (car report) 'buffers:replace!))

(define (condition-text c)
  (cond
    [(not (message-condition? c)) c]
    [(format-condition? c) (apply format (condition-message c) (condition-irritants c))]
    [else (condition-message c)]))

(define (reports-during thunk)
  (map (lambda (c) (list (and (who-condition? c) (condition-who c)) (condition-text c))) (test-runner:reports-during thunk)))

(define (press-reports! keys) (reports-during (lambda () (test-user:press! keys))))

(define (points-after! . keys)
  (let loop ([keys keys] [points '()])
    (if (null? keys)
        (reverse points)
        (begin (test-user:press! (car keys)) (loop (cdr keys) (cons (views:point (view)) points))))))

;; A key runs in a task of its own, which an options:with binding of the
;; test's task does not reach. No dynamic-wind: its exit would run at
;; each pause of the test's task, while the keys run.
(define (with-setting option value thunk)
  (options:set! option value)
  (thunk)
  (options:unset! option))

;; ask's own writer reports each message as a warning, which would fail
;; the test file.
(define %said '())

(define (take-said!) (let ([said (reverse %said)]) (set! %said '()) said))

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
