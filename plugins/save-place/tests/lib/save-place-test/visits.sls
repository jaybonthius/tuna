#!tuna
(import (buffers) (files) (views))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(define (leave! name point)
  (let* ([b (files:visit (home-file name))] [v (views:make b)])
    (views:set-point! v point)
    (views:drop! v)
    (buffers:kill! b)))

(define (reopened-point name) (views:last-point (files:visit (home-file name))))
