#!tuna
(import (test-runner) (options) (ask) (timers) (commands) (buffers) (document) (undo))

(define (end b) (fx- (document:length (buffers:document b)) 1))

(commands:define-command (type text)
  "Inserts TEXT at the end of the current buffer, joining the previous group as typing does."
  (undo:amalgamate!)
  (let ([b (buffers:current)])
    (buffers:replace! b (end b) (end b) text)))

(commands:define-command (insert position text)
  "Inserts TEXT at POSITION in the current buffer."
  (buffers:replace! (buffers:current) position position text))

(commands:define-command (delete start end)
  "Deletes from START to END in the current buffer."
  (buffers:replace! (buffers:current) start end ""))

(commands:define-command (insert-pausing text)
  "Inserts TEXT at the start, pauses, and inserts it again."
  (let ([b (buffers:current)])
    (buffers:replace! b 1 1 text)
    (timers:sleep 0.01)
    (buffers:replace! b 1 1 text)))

(define (run-in b command . args) (buffers:with-buffer b (apply commands:run command args)))

(define (text b) (document:text (buffers:document b)))

(define (tree b)
  (let ([h (undo:history b)])
    (cons* (car h) (cadr h) (map (lambda (s) (list (car s) (cadr s))) (cddr h)))))

(define (parents b) (map cadr (cddr (undo:history b))))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (condition-text c)
  (cond
    [(not (message-condition? c)) c]
    [(format-condition? c) (apply format (condition-message c) (condition-irritants c))]
    [else (condition-message c)]))

(define (reports-during thunk)
  (map (lambda (c) (list (and (who-condition? c) (condition-who c)) (condition-text c)))
       (test-runner:reports-during thunk)))

;; ask's own writer reports each message as a warning, which would fail
;; the test file.
(define %said '())

(define (take-said!) (let ([said (reverse %said)]) (set! %said '()) said))

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
