#!tuna
(import (plugins) (files) (layout) (views) (editing) (command-line handled))

(define (%starts-with? prefix argument)
  (let ([n (string-length prefix)])
    (and (fx>= (string-length argument) n) (string=? (substring argument 0 n) prefix))))

(define (%line-number argument)
  (and (fx> (string-length argument) 1)
       (char=? (string-ref argument 0) #\+)
       (for-all char-numeric? (cdr (string->list argument)))
       (string->number (substring argument 1 (string-length argument)))))

(define (%evaluate! argument)
  (guard (c [(not (cancelled? c)) (report c)])
    (let ([p (open-input-string (substring argument 7 (string-length argument)))])
      (call-as-owner (plugins:repl-owner)
        (lambda ()
          (let loop ()
            (let ([form (read p)])
              (unless (eof-object? form)
                (plugins:eval-form form)
                (loop)))))))))

(define (%visit argument)
  (guard (c [(not (cancelled? c)) (report c) #f])
    (files:visit argument)))

(define (%show! b line)
  (layout:switch-to-buffer b)
  (when line
    (views:set-point! (layout:selected-view) (editing:line-position b line))))

;; Only the last file is shown, so a +N before another file has no view
;; to move.
(define (%handle-arguments! arguments)
  (let loop ([arguments arguments] [line #f] [shown #f])
    (cond
      [(null? arguments) (when shown (%show! (car shown) (cdr shown)))]
      [(%starts-with? "--eval=" (car arguments))
       (%evaluate! (car arguments))
       (loop (cdr arguments) line shown)]
      [(%starts-with? "--" (car arguments))
       (report (condition (make-warning)
                 (make-message-condition
                   (format "unknown flag ~a; the only flag is --eval=EXPR" (car arguments)))))
       (loop (cdr arguments) line shown)]
      [(%line-number (car arguments)) => (lambda (n) (loop (cdr arguments) n shown))]
      [else
       (let ([b (%visit (car arguments))])
         (loop (cdr arguments) #f (if b (cons b line) shown)))])))

(spawn-task (lambda (restore) (%handle-arguments! (take-arguments!))))
