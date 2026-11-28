#!tuna
(import (tuna) (completion) (layout) (views) (test-runner))

(define (session) (views:call-with-view (layout:selected-view) completion:current-session))

(define (matches s)
  (let ([ms (completion:session-matches s)])
    (map (lambda (k) (completion:matches-ref ms k)) (iota (completion:matches-count ms)))))

(define (texts s) (map (lambda (m) (completion:text s m)) (matches s)))

(define (selected-text s)
  (let ([m (completion:selected s)])
    (and m (completion:text s m))))

(define (wait-matches s)
  (test-runner:wait-until (lambda () (not (completion:session-busy? s)))))
