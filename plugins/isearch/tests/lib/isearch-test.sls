#!tuna
(import (test-runner) (options) (ask) (keys) (layout) (views) (buffers) (document) (search) (isearch) (test-user))

(define (view) (layout:selected-view))

(define (point) (views:point (view)))

(define (show! name text)
  (let ([b (buffers:make (buffers:free-name name) text)])
    (layout:switch-to-buffer b)
    (views:set-point! (view) 1)
    b))

(define (%controls-shown text)
  (apply string-append
    (map (lambda (c)
           (let ([n (char->integer c)])
             (if (or (< n 32) (= n 127)) (string #\^ (integer->char (fxlogxor n 64))) (string c))))
         (string->list text))))

(define prompt
  (case-lambda
    [() (prompt (test-user:client))]
    [(client)
     (let ([p (keys:prompt client)])
       (cond
         [(not p) #f]
         [(string? p) (%controls-shown p)]
         [else
          (apply string-append
            (map (lambda (part)
                   (cond
                     [(string? part) (%controls-shown part)]
                     [(car part) (string-append "{" (%controls-shown (cdr part)) "}")]
                     [else (%controls-shown (cdr part))]))
                 p))]))]))

(define (%text-of v m)
  (buffers:text-between (buffers:document (views:buffer v)) (search:match-start m) (search:match-end m)))

(define here
  (case-lambda
    [() (here (test-user:client))]
    [(client)
     (let* ([s (isearch:current client)] [m (and s (isearch:search-match s))])
       (list (point) (prompt client) (and m (%text-of (isearch:search-view s) m))))]))

(define (wait-scan)
  (let ([s (isearch:current (test-user:client))])
    (when s (test-runner:wait-until (lambda () (search:scan-done? (isearch:search-scan s)))))))

(define (view-element client v)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen client) "data-view"))))

(define faced
  (case-lambda
    [(client) (faced client (view))]
    [(client v)
     (test-user:settle)
     (let ([e (view-element client v)])
       (if e
           (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
                (test-user:elements-with e "data-face"))
           '()))]))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

;; Keys that end a search by cancelling it raise &cancelled, which the
;; command's report carries.
(define cancelling!
  (case-lambda
    [(keys) (cancelling! (test-user:client) keys)]
    [(client keys)
     (let ([reports (reports-during (lambda () (test-user:press! client keys)))])
       (and (pair? reports) (for-all cancelled? reports)))]))

;; A key runs in a task of its own, which an options:with binding of the
;; test's task does not reach.
(define (with-setting option value thunk)
  (options:set! option value)
  (thunk)
  (options:unset! option))

(define %said '())

(define (take-said!) (let ([said (reverse %said)]) (set! %said '()) said))

;; ask's own writer reports each message as a warning, which would fail
;; the test file.
(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
