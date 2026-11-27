#!tuna
(import (test-runner) (options) (ask) (buffers) (document) (processes) (runs))

(define home (processes:options [directory "~/"]))

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (touch! name) (with-output-to-file (home-path name) void))

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
                  [(and (char=? (string-ref s i) #\newline) (%index s "Run " (+ i 1)) (= (%index s "Run " (+ i 1)) (+ i 1))) i]
                  [else (loop (- i 1))]))])
    (substring s start (max start (- end 1)))))

(define (%digit? s i) (and (< i (string-length s)) (char-numeric? (string-ref s i))))

;; A run's times differ at each run, and only their form is the plugin's.
(define (lines b)
  (let ([s (text b)])
    (let loop ([i 0] [out '()])
      (cond
        [(= i (string-length s))
         (let split ([cs (reverse out)] [line '()] [acc '()])
           (cond
             [(null? cs) (reverse (if (null? line) acc (cons (list->string (reverse line)) acc)))]
             [(char=? (car cs) #\newline) (split (cdr cs) '() (cons (list->string (reverse line)) acc))]
             [else (split (cdr cs) (cons (car cs) line) acc)]))]
        [(and (%digit? s i) (<= (+ i 19) (string-length s)) (char=? (string-ref s (+ i 4)) #\-)
              (char=? (string-ref s (+ i 13)) #\:))
         (loop (+ i 19) (append (reverse (string->list "TIME")) out))]
        [(and (%index s "after " i) (= (%index s "after " i) i) (%digit? s (+ i 6)))
         (loop (%index s " s" i) (append (reverse (string->list "after S")) out))]
        [else (loop (+ i 1) (cons (string-ref s i) out))]))))

(define %said '())

(define (take-said!) (let ([said (reverse %said)]) (set! %said '()) said))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (raised thunk)
  (guard (c [(and (who-condition? c) (message-condition? c))
             (list (condition-who c) (condition-message c) (if (irritants-condition? c) (condition-irritants c) '()))])
    (thunk)
    'none))

;; A run's result must not depend on the user's shell, which may not be POSIX.
(options:set! runs:shell '("/bin/sh" "-c"))

;; ask's own writer reports each message as a warning, which would fail
;; the test file.
(options:set! ask:message-writer (lambda (text) (set! %said (cons text %said))))
