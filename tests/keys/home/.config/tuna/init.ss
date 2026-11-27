(import (hooks) (options) (tables) (timers) (plugins))
(import (tuna) (testing) (commands) (groucho))
(use-plugin keys
  (config
    (options:set! keys:right-option-meta? #f)
    (keys:bind! keys:global "C-c g o" groucho:browse-remote)))
(import (layout) (cape) (editing) (vertico))
;; Loaded, not imported, so its unload in a test stays an unload.
(load-module! '(file-picker))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))


(define (on-thread thunk)
  (let ([result #f])
    (fork-task (lambda (restore) (set! result (raised thunk))))
    (testing:wait-until (lambda () result))
    result))

(define (name-of v)
  (cond
    [(commands:command? v) (commands:command-name v)]
    [(eq? v keys:global) 'keys:global]
    [(tables:table? v) 'keymap]
    [else v]))

(define (press-all! frame . keys)
  (for-each (lambda (key) (keys:press! frame key)) keys))
(import (console))
