(import (tuna) (tuna plugins) (web) (keys) (commands) (document) (buffers) (views) (modes) (processes))
(use-plugin layout)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin files)
(use-plugin undo)
(use-plugin buffer-picker)
(use-plugin runs
  (config
    (set-option! runs:shell '("/bin/sh" "-c"))))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (ended? b) (wait-until (lambda () (runs:status b))) (runs:status b))

(define (text b) (document:text (buffers:document b)))

(define (search s needle from)
  (let ([n (string-length needle)])
    (let loop ([i from])
      (cond
        [(> (+ i n) (string-length s)) #f]
        [(string=? (substring s i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

;; The text with each date and time as TIME, a duration as S, and the
;; home folder as ~.
(define (shown b)
  (let loop ([s (text b)] [out '()] [i 0])
    (cond
      [(= i (string-length s)) (list->string (reverse out))]
      [(and (<= (+ i 19) (string-length s)) (char-numeric? (string-ref s i))
            (char=? (string-ref s (+ i 4)) #\-) (char=? (string-ref s (+ i 13)) #\:))
       (loop s (append (reverse (string->list "TIME")) out) (+ i 19))]
      [(and (search s "after " i) (= (search s "after " i) i))
       (let ([e (search s " s" i)])
         (loop s (append (reverse (string->list "after S")) out) e))]
      [else (loop s (cons (string-ref s i) out) (+ i 1))])))

(define (show b) (display (shown b)))

;; The output alone: the text between the header and the footer.
(define (output b)
  (let* ([s (text b)] [start (+ (search s "\n\n" 0) 2)] [start (+ (search s "\n" start) 1)]
         [end (let loop ([i (- (string-length s) 2)])
                (cond
                  [(< i start) (+ (string-length s) 1)]
                  [(and (char=? (string-ref s i) #\newline) (string=? (substring s (+ i 1) (+ i 5)) "Run ")) i]
                  [else (loop (- i 1))]))])
    (substring s start (max start (- end 1)))))

(define home (processes:options [directory "~/"]))

(define ends '())
(add-hook! runs:ended (lambda (b end) (set! ends (cons (list (buffers:name b) end (runs:status b)) ends))))
(define (taken-ends) (let ([e (reverse ends)]) (set! ends '()) e))

(define (message) (echo-area:current-message))

(define (spans b)
  (buffers:spans (buffers:layer b runs:%styles) 0 (document:length (buffers:document b))))
(import (tuna eval))
(define library (getenv "TUNA_LIBRARY"))
(define (reload! name) (eval-file (string-append library "/" name ".sls")))
(import (console))
