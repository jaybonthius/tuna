(import (hooks) (options) (timers) (plugins))
(import (tuna) (testing) (document))
;; ask's own writer raises each message as a warning, whose handler runs
;; outside the guards of the code that said it.
(use-plugin ask
  (config
    (options:set! ask:message-writer (lambda (text) (void)))))
;; Loaded, not imported, so an unload in a test stays an unload.
(load-module! '(undo-log))
(load-module! '(checks))

(define (text b) (document:text (buffers:document b)))

(define (tree b)
  (let ([h (undo:history b)])
    (cons* (car h) (cadr h) (map (lambda (s) (list (car s) (cadr s))) (cddr h)))))

(define (raised thunk)
  (guard (c [#t (list (condition-who c) (condition-message c))])
    (thunk)))

(import (console))
