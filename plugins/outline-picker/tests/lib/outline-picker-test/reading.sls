#!tuna
(import (buffers) (document) (views) (layout) (editing) (completion) (test-user) (test-runner)
        (completion-test sessions) (completion-test picking))

(define (view) (layout:selected-view))

(define (place-of v)
  (let* ([b (views:buffer v)] [doc (buffers:document b)] [p (views:point v)])
    (list (buffers:name b) (document:line doc p) (document:column doc p))))

(define (here) (place-of (view)))

(define (go! b line column)
  (layout:switch-to-buffer b)
  (views:set-point! (view) (editing:line-position b line column)))

(define (session) (completion-test/picking:session))

;; The command asks for the outlines before it reads, which can take
;; more than the batches a key's press waits for.
(define (rows)
  (test-runner:wait-until (lambda () (session)))
  (completion-test/picking:choices)
  (let ([s (session)])
    (map (lambda (m) (list (completion:title s m) (completion:text s m))) (completion-test/sessions:matches s))))

(define (quit!)
  (let ([reported (completion-test/picking:quit!)])
    (unless (equal? '(cancelled) reported)
      (assertion-violation 'outline-picker-test/reading:quit! "C-g did not end the read with one cancel" reported))))
