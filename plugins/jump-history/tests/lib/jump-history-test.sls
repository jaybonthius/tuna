#!tuna
(import (hooks) (commands) (buffers) (document) (views) (layout) (completion) (jump-history) (test-runner) (test-user))

(define (view) (layout:selected-view))

(define (reports-during thunk)
  (map (lambda (c) (if (cancelled? c) 'cancelled (list (condition-who c) (condition-message c)))) (test-runner:reports-during thunk)))

(define (press-reporting! keys) (reports-during (lambda () (test-user:press! keys))))

;; A command may pause past test-user:settle, as when it visits a file
;; or lists a folder, so a test that needs it done waits for its end.
(define %ended '())

(define (press-until-ended! keys command)
  (set! %ended '())
  (test-user:press! keys)
  (test-runner:wait-until (lambda () (memq command %ended))))

(define (session) (views:call-with-view (view) completion:current-session))

(define (choices)
  (let ([s (session)])
    (test-runner:wait-until (lambda () (not (completion:session-busy? s))))
    (let ([ms (completion:session-matches s)])
      (map (lambda (k) (let ([m (completion:matches-ref ms k)]) (list (completion:title s m) (completion:text s m))))
           (iota (completion:matches-count ms))))))

(define (line-of b p) (document:line (buffers:document b) p))

(define (here) (let ([v (view)]) (list (buffers:name (views:buffer v)) (line-of (views:buffer v) (views:point v)))))

(define (places) (map (lambda (p) (list (buffers:name (car p)) (line-of (car p) (cdr p)))) (jump-history:places)))

(define (line! n)
  (let ([v (view)]) (views:set-point! v (document:line-start (buffers:document (views:buffer v)) n))))

(define (view-element v)
  (test-user:settle)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (pulsed v)
  (let loop ([elements (test-user:elements-with (view-element v) "data-face")] [acc '()])
    (cond
      [(null? elements) (reverse acc)]
      [(equal? "pulse.highlight" (test-user:element-attribute (car elements) "data-face"))
       (let ([text (test-user:element-text (car elements))])
         (loop (list-tail elements (length (test-user:elements-with (car elements) "data-face"))) (cons text acc)))]
      [else (loop (cdr elements) acc)])))

(hooks:add! commands:after-command (lambda (command) (set! %ended (cons command %ended))))
