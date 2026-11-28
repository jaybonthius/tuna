#!tuna
(import (test-runner) (options) (commands) (layout) (views) (buffers) (document) (minibuffer) (echo-area) (runs))

(define (view) (layout:selected-view))

(define (run command . arguments) (views:with-view (view) (apply commands:run command arguments)))

(define (home-path path) (string-append (getenv "HOME") "/" path))

(define (folder! path) (mkdir (home-path path)))

(define (write-file! path text) (with-output-to-file (home-path path) (lambda () (display text))))

(define (touch! path) (with-output-to-file (home-path path) void))

(define (ended b)
  (test-runner:wait-until (lambda () (runs:status b)))
  (runs:status b))

(define (text b) (document:text (buffers:document b)))

(define (%index s needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length s)) #f]
        [(string=? (substring s i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (output b)
  (let* ([s (text b)] [start (+ (%index s "\n" (+ (%index s "\n\n" 0) 2)) 1)]
         [end (let loop ([i (- (string-length s) 2)])
                (cond
                  [(< i start) (+ (string-length s) 1)]
                  [(eqv? (%index s "\nRun " i) i) i]
                  [else (loop (- i 1))]))])
    (substring s start (max start (- end 1)))))

(define (header-folder b)
  (let* ([s (text b)] [i (+ (%index s " in " 0) 4)]) (substring s i (%index s "\n" i))))

(define (output-text) (text (buffers:find "*Shell Command Output*")))

(define (message) (echo-area:current-message))

(define (input) (minibuffer:input (minibuffer:current-prompt)))

(define (shown)
  (map (lambda (v) (buffers:name (views:buffer v)))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define (regions)
  (map (lambda (c) (list (views:cursor-mark c) (views:cursor-point c))) (views:cursors (view))))

(define (regions! b . ranges)
  (layout:switch-to-buffer b)
  (views:set-cursor! (car (views:cursors (view))) (cadar ranges) (caar ranges))
  (for-each (lambda (r) (views:set-cursor! (views:add-cursor! (view) (cadr r)) (cadr r) (car r))) (cdr ranges))
  (regions))

;; A run's result must not depend on the user's shell, which may not be POSIX.
(options:set! runs:shell '("/bin/sh" "-c"))
