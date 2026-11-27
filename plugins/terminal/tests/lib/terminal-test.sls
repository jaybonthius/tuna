#!tuna
(import (test-runner) (test-user) (options) (buffers) (document) (views) (layout) (web) (terminal))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (text b) (document:text (buffers:document b)))

(define (lines s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (if (< start i) (cons (substring s start i) acc) acc))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (index-of s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length s)) #f]
        [(string=? (substring s i (+ i n)) part) i]
        [else (loop (+ i 1))]))))

;; An offset at a node's edge names the position before the node's
;; tokens, so the position of a character is found from the one after it.
(define (position-of b part)
  (let* ([doc (buffers:document b)] [i (index-of (document:text doc) part)])
    (unless i (assertion-violation 'terminal-test:position-of "not in the buffer" part))
    (- (document:position doc (+ i 1) (document:unit characters)) 1)))

(define (screen-has? t part) (and (index-of (terminal:screen-text t) part) #t))

;; A program's output reaches the screen on the main thread as processes
;; delivers it, so a check waits for the text it expects.
(define (wait-for t part)
  (guard (c [(and (who-condition? c) (eq? (condition-who c) 'test-runner:wait-until))
             (errorf 'terminal-test:wait-for "~s never showed ~s; its screen is ~s" (buffers:name t) part
                     (terminal:screen-text t))])
    (test-runner:wait-until (lambda () (screen-has? t part)))))

(define (screen-lines t)
  (let loop ([ls (reverse (lines (terminal:screen-text t)))])
    (if (and (pair? ls) (string=? (car ls) "")) (loop (cdr ls)) (reverse ls))))

;; A shell whose prompt is the same on every machine.
(define (shell!)
  (options:set! terminal:shell '("bash" "--norc" "--noprofile"))
  (options:set! terminal:environment '(("PS1" . "$ ") ("PS2" . "> ") ("HISTFILE" . #f)))
  (let ([t (terminal:start #f)])
    (wait-for t "$ ")
    t))

;; As a command run by a key of test-user's client starts it, so that
;; client's input reached it last.
(define (start-for-client command)
  (parameterize ([web:current-client (test-user:client)]) (terminal:start command)))

(define (show! b)
  (views:set-buffer! (layout:selected-view) b)
  (test-user:settle))

(define (view) (layout:selected-view))

;; The input modes are minor modes, read in the current view.
(define (in-view thunk) (views:call-with-view (layout:selected-view) thunk))

(define (input-mode)
  (in-view (lambda () (cond [(terminal:copy-mode?) 'copy] [(terminal:char-mode?) 'char] [(terminal:semi-char-mode?) 'semi-char] [else #f]))))

(define (reader n . setup)
  (let ([t (start-for-client
             (list "sh" "-c"
               (format "stty raw -echo; ~aecho ready; dd bs=1 count=~a 2>/dev/null | od -An -tx1 | tr -s ' \\n' ' '; echo; echo end; read x"
                 (apply string-append setup) n)))])
    (wait-for t "ready")
    t))

(define (read-by t)
  (wait-for t "end")
  (let ([read (cadr (screen-lines t))])
    (let trim ([i 0])
      (if (char=? (string-ref read i) #\space)
          (trim (+ i 1))
          (substring read i (- (string-length read) 1))))))

(define (bytes-read steps n . setup)
  (let ([t (apply reader n setup)])
    (show! t)
    (for-each (lambda (step) (if (procedure? step) (step) (test-user:press! step))) steps)
    (let ([read (read-by t)])
      (buffers:kill! t)
      read)))
