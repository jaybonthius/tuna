(import (hooks) (options) (tables) (timers))
(import (tuna) (testing) (document))
;; ask's own writer raises each message as a warning, whose handler runs
;; outside the guards of the code that said it; the tests keep the
;; messages to read them.
(define said '())
(use-plugin ask
  (config
    (options:set! ask:message-writer (lambda (text) (set! said (cons text said))))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))
(use-plugin undo
  (config
    (keys:bind! keys:global "C-z" undo:undo)
    (keys:bind! keys:global "C-Z" undo:redo)))
(import (checks))

(define (text b) (document:text (buffers:document b)))

(define (tree b)
  (let ([h (undo:history b)])
    (cons* (car h) (cadr h) (map (lambda (s) (list (car s) (cadr s))) (cddr h)))))

(define (raised thunk)
  (guard (c [#t (list (condition-who c) (condition-message c))])
    (thunk)))

(import (console))
