(import (tuna) (tuna plugins) (commands) (groucho))
(use-plugin keys
  (config
    (set-option! keys:right-option-meta? #f)
    (keys:bind! keys:global "C-c g o" groucho:browse-remote)))
(import (layout) (files) (cape) (editing) (vertico))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (on-thread thunk)
  (let ([result #f])
    (fork-thread (lambda () (set! result (raised thunk))))
    (wait-until (lambda () result))
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
