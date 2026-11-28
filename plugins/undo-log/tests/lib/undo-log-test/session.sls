#!tuna
(import (test-runner) (options) (ask) (document) (buffers) (files) (layout) (views) (undo-log))

(define (home-path name) (string-append (getenv "HOME") "/" name))

;; A file, since what is noted as Tuna exits must outlive the process.
(define (note! text)
  (call-with-output-file (home-path "events") (lambda (p) (put-string p text) (newline p)) 'append))

(define (b) (files:buffer-visiting (home-path "b.txt")))

(define (text) (document:text (buffers:document (b))))

(define (shown)
  (let* ([v (layout:selected-view)] [buffer (views:buffer v)] [doc (buffers:document buffer)] [point (views:point v)])
    (list (buffers:name buffer) (document:line doc point)
          (document:text doc point (min (+ point 5) (document:length doc))))))

(define (points) (map views:cursor-point (views:cursors (layout:selected-view))))

(define (wait-for-restart!)
  (test-runner:wait-until
    (lambda () (and (= (length (files:buffers)) 2) (b) (eq? (views:buffer (layout:selected-view)) (b))))))

;; The test home is under /tmp, where undo-log keeps no log by default.
(options:set! undo-log:keep-log? (lambda (path) #t))
(options:set! ask:message-writer (lambda (text) (note! (string-append "said: " text))))
(options:set! ask:yes-or-no-reader (lambda (question) (note! (string-append "asked: " question)) #t))
