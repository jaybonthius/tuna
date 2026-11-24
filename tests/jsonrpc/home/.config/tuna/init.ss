(import (tuna) (testing) (tuna plugins) (web) (keys) (views) (buffers) (document) (modes) (processes) (json-rpc))
(use-plugin layout)
(use-plugin editing)
(use-plugin jsonrpc)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (shown) (buffers:name (views:buffer (layout:selected-view))))

(define tuna-program (car (command-line)))

(define libraries (string-append (path-parent tuna-program) "/libraries"))

(define home (getenv "HOME"))

(define records 0)

(define last-record #f)

(define (start-fake! name handlers)
  (set! records (+ records 1))
  (let ([record (format "~a/record-~a" home records)])
    (let ([c (jsonrpc:start name
               (list tuna-program "--script" (string-append home "/fake-server.ss") libraries record)
               handlers)])
      (set! last-record record)
      c)))

(define (record-of path)
  (if (file-exists? path)
      (call-with-input-file path
        (lambda (p)
          (let loop ([lines '()])
            (let ([line (get-line p)])
              (if (eof-object? line) (reverse lines) (loop (cons line lines)))))))
      '()))


(define (recorded path) (testing:wait-until (lambda () (pair? (record-of path)))) (record-of path))

(define (log-text c) (document:text (buffers:document (jsonrpc:events-buffer c))))

(define (log-lines c)
  (let loop ([s (log-text c)] [lines '()] [start 0] [i 0])
    (cond
      [(= i (string-length s)) (reverse lines)]
      [(char=? (string-ref s i) #\newline)
       (loop s (cons (substring s start i) lines) (+ i 1) (+ i 1))]
      [else (loop s lines start (+ i 1))])))

(define make-quit (record-constructor (record-constructor-descriptor &quit)))

(define cancels '())

(define (note-cancel! c id) (set! cancels (cons id cancels)))

(define (raised thunk)
  (guard (c [(json-rpc-error? c) (list 'json-rpc-error (json-rpc-error-code c) (condition-message c))]
            [(jsonrpc:ended? c) (list 'ended (jsonrpc:ended-status c))]
            [(jsonrpc:timeout? c) (list 'timeout (jsonrpc:timeout-method c))])
    (thunk)))

(import (console))
