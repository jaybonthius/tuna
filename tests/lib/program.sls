#!tuna
(import (processes) (test-runner))

(define-record-type (%run %make-run %run?)
  (sealed #t)
  (fields process (mutable output) (mutable errors) (mutable status)))

(define (tuna) (car (command-line)))

;; The program runs as a user would run it, in a home test-runner made,
;; which holds the install's compiled plugins, so it compiles none of them.
(define (start program home arguments environment)
  (let* ([r #f]
         [process
          (processes:start program arguments
            (lambda (bytes end) (unless (eof-object? bytes) (%run-output-set! r (cons bytes (%run-output r)))))
            (lambda (status) (%run-status-set! r status))
            (processes:options
              [directory home]
              [environment (append environment
                             (remp (lambda (entry) (assoc (car entry) environment))
                                   (test-runner:home-environment home)))])
            (lambda (bytes end) (unless (eof-object? bytes) (%run-errors-set! r (cons bytes (%run-errors r))))))])
    (set! r (%make-run process '() '() #f))
    r))

(define (send! r text) (processes:send! (%run-process r) text))

(define (close-input! r) (processes:close-input! (%run-process r)))

(define (signal! r name) (processes:signal! (%run-process r) name))

(define (pid r) (processes:pid (%run-process r)))

(define (ended? r) (and (%run-status r) #t))

;; A program that never ends is stopped, so the test fails in its own
;; check rather than at the file's time limit.
(define (wait r)
  (guard (c [#t (processes:stop! (%run-process r)) (raise c)])
    (test-runner:wait-until (lambda () (%run-status r))))
  (values (%run-status r) (%text (%run-output r)) (%text (%run-errors r))))

(define (%text pieces)
  (utf8->string
    (call-with-bytevector-output-port
      (lambda (p) (for-each (lambda (piece) (put-bytevector p piece)) (reverse pieces))))))

;; With its standard input closed at once, as a program run from a script.
(define run
  (case-lambda
    [(home arguments) (run (tuna) home arguments '())]
    [(home arguments environment) (run (tuna) home arguments environment)]
    [(program home arguments environment)
     (let ([r (start program home arguments environment)])
       (close-input! r)
       (wait r))]))
