#!tuna
(import (eval) (timers))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (library-file name)
  (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls"))

(define (write-module! path text edit)
  (call-with-output-file path
    (lambda (p) (put-string p text) (fprintf p ";; edit ~a\n" edit))
    'replace))

(define small-text
  "#!tuna\n(import (options) (hooks))\n(options:define-option width 70 fixnum? \"Width.\")\n(hooks:define-hook after-run)\n(define (greet name) (string-append \"Hello, \" name \"!\"))\n(define (count xs) (length xs))\n(hooks:add! after-run count)\n")

;; Sized as a typical plugin's file.
(define big-text
  (call-with-string-output-port
    (lambda (p)
      (put-string p "#!tuna\n")
      (do ([k 0 (+ k 1)]) ((= k 28))
        (fprintf p "(define (h~a xs n)\n  (let loop ([xs xs] [i 0] [acc '()])\n    (cond\n      [(null? xs) (reverse acc)]\n      [(> i n) (append (reverse acc) xs)]\n      [(string? (car xs)) (loop (cdr xs) (+ i 1) (cons (string-append (car xs) \"-~a\") acc))]\n      [(number? (car xs)) (loop (cdr xs) (+ i 1) (cons (* (car xs) ~a) acc))]\n      [else (loop (cdr xs) (+ i 1) (cons (list (car xs)) acc))])))\n\n" k k (+ k 1))))))

;; Each edit adds a comment line, so the module is compiled again. File
;; times are coarse, so an edit made in the tick its object was written in
;; would not look newer; each edit waits a little first.
(define (reload-ms path text edited? runs)
  (median
    (map (lambda (i)
           (when edited?
             (timers:sleep 0.02)
             (write-module! path text i))
           (let ([start (now-ns)])
             (eval:eval-file path)
             (/ (- (now-ns) start) 1e6)))
         (iota runs))))

(define (run)
  (let ([small (library-file "small")] [big (library-file "big")])
    (write-module! small small-text 'first)
    (write-module! big big-text 'first)
    (eval:eval-file small)
    (eval:eval-file big)
    (printf "reload-unchanged-small ~,2f\n" (reload-ms small small-text #f 21))
    (printf "reload-edited-small ~,2f\n" (reload-ms small small-text #t 11))
    (printf "reload-edited-big ~,2f\n" (reload-ms big big-text #t 7))))
