#!tuna
(import (options) (ask) (commands) (buffers) (document) (undo))

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

(commands:define-command (kill [buffer (buffers:current)])
  "Kills BUFFER."
  (buffers:kill! buffer))

(define (run-in b command . args) (buffers:with-buffer b (apply commands:run command args)))

(define (tree b)
  (let ([h (undo:history b)])
    (cons* (car h) (cadr h) (map (lambda (s) (list (car s) (cadr s))) (cddr h)))))

(define (states b) (map (lambda (s) (list (car s) (cadr s))) (cddr (undo:history b))))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

;; ask's own writer reports each message as a warning, which would fail
;; the test file.
(define %said '())

(define (take-said!) (let ([said (reverse %said)]) (set! %said '()) said))

(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
