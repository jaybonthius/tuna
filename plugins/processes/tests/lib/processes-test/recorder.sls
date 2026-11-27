#!tuna
(import (test-runner))

(define-record-type (%recorder make recorder?)
  (sealed #t)
  (fields (mutable events))
  (protocol (lambda (new) (lambda () (new '())))))

(define (%note! r event) (%recorder-events-set! r (cons event (%recorder-events r))))

(define (on-output r)
  (lambda (bytes end)
    (%note! r (if (eof-object? bytes) (list 'eof end) (list 'output (utf8->string bytes) end)))))

(define (on-error-output r)
  (lambda (bytes end)
    (%note! r (if (eof-object? bytes) (list 'error-eof end) (list 'error (utf8->string bytes) end)))))

(define (on-exit r) (lambda (status) (%note! r (list 'exit status))))

(define (exited? r) (exists (lambda (event) (eq? (car event) 'exit)) (%recorder-events r)))

;; Oldest first, each run of pieces of one stream joined, since a
;; program's writes may arrive in one read or several.
(define (events r)
  (let loop ([events (reverse (%recorder-events r))] [joined '()])
    (cond
      [(null? events) (reverse joined)]
      [(and (pair? joined) (memq (car (car events)) '(output error)) (eq? (car (car events)) (car (car joined))))
       (loop (cdr events)
             (cons (list (car (car events)) (string-append (cadr (car joined)) (cadr (car events))) (caddr (car events)))
                   (cdr joined)))]
      [else (loop (cdr events) (cons (car events) joined))])))

(define (wait-for-exit r)
  (test-runner:wait-until (lambda () (exited? r)))
  (events r))
