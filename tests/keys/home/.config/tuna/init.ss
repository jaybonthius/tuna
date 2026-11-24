(import (tuna) (testing) (tuna plugins) (commands) (groucho))
(use-plugin keys
  (config
    (set-option! keys:right-option-meta? #f)
    (keys:bind! keys:global "C-c g o" groucho:browse-remote)))
(import (layout) (file-picker) (cape) (editing) (vertico))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))


(define (on-thread thunk)
  (let ([result #f])
    (fork-thread (lambda () (set! result (raised thunk))))
    (testing:wait-until (lambda () result))
    result))

(define (name-of v)
  (cond
    [(commands:command? v) (commands:command-name v)]
    [(eq? v keys:global) 'keys:global]
    [(table? v) 'keymap]
    [else v]))

(define (press-all! frame . keys)
  (for-each (lambda (key) (keys:press! frame key)) keys))
(import (console))
