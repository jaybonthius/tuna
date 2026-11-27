#!tuna
(import (layout) (layout-split) (buffers) (document) (views) (commands) (keys) (minibuffer) (echo-area) (web) (test-user)
        (layout-test parts))

;; Each view a test names is called by that name, or by its buffer's, so
;; results read as the names the cases use.
(define %names '())

(define (name! v name) (set! %names (cons (cons v name) %names)) v)

(define (view-named name)
  (let ([b (or (buffers:find name) (buffers:make name (string-append name "\n")))])
    (name! (views:make b) name)))

(define (who v)
  (cond
    [(not v) #f]
    [(assq v %names) => cdr]
    [else (buffers:name (views:buffer v))]))

(define (selected) (who (layout:selected-view)))

(define (order) (map who (layout:selection-order)))

(define (shown) (map who (layout:views)))

(define (front n) (map buffers:name (list-head (buffers:all) n)))

(define echo-buffer (buffers:find " *Echo Area*"))

(define (echo) (layout:find-view echo-buffer))

(define (reset! part)
  (layout-test/parts:set-parts! part)
  (name! ((layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))) echo-buffer) "echo")
  (void))

(define (begin! name)
  (let ([v (view-named name)])
    (reset! (layout-test/parts:atom v))
    (layout:select! v)
    v))

(define (made-beside v name)
  (name! (find (lambda (w) (not (or (eq? w v) (assq w %names) (layout:locked? (layout:view-node w))))) (layout:views)) name))

(define (explorer!)
  (name! ((layout-split:display-at-side (layout:direction left) 50 '(columns 20))
          (or (buffers:find "explorer") (buffers:make "explorer" "x\n")))
         "explorer"))

(define (enclosing v) (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node v))))

(define (in-client thunk)
  (parameterize ([web:current-client (test-user:client)])
    (views:call-with-view (layout:selected-view) thunk)))

(define (prompt-view) (let ([p (minibuffer:current-prompt)]) (and p (minibuffer:prompt-view p))))

(define %answer #f)

(commands:define-command (ask-question)
  "Asks a question in the minibuffer and keeps the answer, or quit when it was quit."
  (set! %answer 'waiting)
  (set! %answer (guard (c [(cancelled? c) 'quit]) (minibuffer:read "Q: "))))

(define (answer) %answer)

(define (ask!) (test-user:press! "C-c q"))

(define (end-prompt!)
  (if (eq? (layout:selected-view) (prompt-view))
      (test-user:press! "C-g")
      (begin (in-client (lambda () (commands:run minibuffer:abort))) (test-user:settle))))

(define (prompt!) (ask!) (end-prompt!))

(keys:bind! keys:global "C-c q" ask-question)
