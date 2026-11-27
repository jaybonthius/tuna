#!tuna
(import (buffers) (document) (jsonrpc) (json-rpc) (test-runner))

(define %records 0)

;; The stand-in server is a Chez script, not a test file, so it sits in
;; lib/; a test reaches its plugin's files in the install's copy.
(define (start! name handlers)
  (set! %records (+ %records 1))
  (let ([record (format "~a/record-~a" (getenv "HOME") %records)] [tuna (car (command-line))])
    (values
      (jsonrpc:start name
        (list tuna "--script" (string-append (path-parent tuna) "/plugins/jsonrpc/tests/lib/fake-server.ss")
              (string-append (path-parent tuna) "/libraries") record)
        handlers)
      record)))

(define (start name handlers) (let-values ([(c record) (start! name handlers)]) c))

(define (record-of path)
  (if (file-exists? path)
      (call-with-input-file path
        (lambda (p)
          (let loop ([lines '()])
            (let ([line (get-line p)])
              (if (eof-object? line) (reverse lines) (loop (cons line lines)))))))
      '()))

(define (wait-for-records path count)
  (test-runner:wait-until (lambda () (>= (length (record-of path)) count))))

(define (log-text c) (document:text (buffers:document (jsonrpc:events-buffer c))))

(define (log-lines c)
  (let loop ([s (log-text c)] [lines '()] [start 0] [i 0])
    (cond
      [(= i (string-length s)) (reverse lines)]
      [(char=? (string-ref s i) #\newline) (loop s (cons (substring s start i) lines) (+ i 1) (+ i 1))]
      [else (loop s lines start (+ i 1))])))

(define (raised thunk)
  (guard (c [(json-rpc-error? c) (list 'json-rpc-error (json-rpc-error-code c) (condition-message c))]
            [(jsonrpc:ended? c) (list 'ended (jsonrpc:ended-status c))]
            [(jsonrpc:timeout? c) (list 'timeout (jsonrpc:timeout-method c))])
    (thunk)))
