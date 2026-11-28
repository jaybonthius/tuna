#!tuna
(import (tuna) (test-runner) (test-user))

(define (first-element class)
  (let ([found (test-user:elements (test-user:screen) class)])
    (and (pair? found) (car found))))

(define (bracket)
  (let ([e (first-element "minibuffer-message")])
    (and e (test-user:element-text e))))

(define (bracket-face)
  (let ([e (first-element "minibuffer-message")])
    (and e (test-user:element-attribute e "data-face"))))

(define (questions) (map test-user:element-text (test-user:elements (test-user:screen) "minibuffer-question")))

(define (question)
  (let ([shown (questions)])
    (and (pair? shown) (car (last-pair shown)))))

(define (echo-drawn?) (and (first-element "echo-area-message") #t))

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (test-runner:reports-during thunk)))
